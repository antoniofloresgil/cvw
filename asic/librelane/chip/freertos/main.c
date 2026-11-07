/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * FreeRTOS demo for asic_soc_rv32imac.  Tasks, a queue, a mutex and a software timer, printing on the
 * UART the bootloader left set up.  A low priority task that never blocks checks that the tick
 * preempts it: the producer (priority 2) wakes every 5 ticks and the consumer (priority 3) prints
 * what it receives; after 5 messages the consumer checks the tick count, the timer's expiries and the
 * stacks, and prints "FREERTOS OK" (or "FREERTOS FAIL" and the reason). */
#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "semphr.h"
#include "timers.h"

#define UART_BASE   0x10000000UL
#define UART_THR    ( *( volatile uint8_t * ) ( UART_BASE + 0 ) )
#define UART_LSR    ( *( volatile uint8_t * ) ( UART_BASE + 5 ) )   /* bit 5: transmit holding empty */

#define MESSAGES        5
#define PRODUCER_TICKS  5
#define TIMER_TICKS     7

extern void * volatile pxCurrentTCB;     /* tasks.c; its first member is the saved context's address */

static uint32_t ulTryStore( volatile uint32_t * p );
static uint32_t ulTryJump( void * p );
static void vBusyTask( void * pv );

static QueueHandle_t xQueue;
static SemaphoreHandle_t xUartMutex;
static volatile uint32_t ulTimerExpiries;
static volatile uint32_t ulBusyCount;
static volatile uint32_t ulExpectFault;     /* set around an access the PMP must refuse */
static volatile uint32_t ulFaultCause;      /* what the exception handler saw: mcause, 0 if none */

static void uart_putc( char c )
{
    while( ( UART_LSR & 0x20 ) == 0 )
    {
    }
    UART_THR = ( uint8_t ) c;
}

static void uart_puts( const char * s )
{
    while( *s )
    {
        uart_putc( *s++ );
    }
}

static void uart_putu( uint32_t v )
{
    char digits[ 11 ];
    int n = 0;

    do
    {
        digits[ n++ ] = ( char ) ( '0' + v % 10 );
        v /= 10;
    } while( v );

    while( n )
    {
        uart_putc( digits[ --n ] );
    }
}

static void print_line( const char * s, uint32_t v )
{
    xSemaphoreTake( xUartMutex, portMAX_DELAY );
    uart_puts( s );
    uart_putu( v );
    uart_putc( '\n' );
    xSemaphoreGive( xUartMutex );
}

static void vBusyTask( void * pv )
{
    ( void ) pv;

    for( ; ; )
    {
        ulBusyCount++;      /* never blocks: only the tick interrupt takes the CPU from it */
    }
}

static void vProducerTask( void * pv )
{
    ( void ) pv;

    for( uint32_t n = 1; n <= MESSAGES; n++ )
    {
        vTaskDelay( PRODUCER_TICKS );
        xQueueSend( xQueue, &n, portMAX_DELAY );
    }

    vTaskSuspend( NULL );
}

static void vConsumerTask( void * pv )
{
    uint32_t n, expected = 1;
    const char * fail = NULL;

    ( void ) pv;

    while( expected <= MESSAGES )
    {
        xQueueReceive( xQueue, &n, portMAX_DELAY );
        print_line( "rx ", n );
        if( n != expected++ )
        {
            fail = "queue order";
        }
    }

    if( xTaskGetTickCount() < MESSAGES * PRODUCER_TICKS )
    {
        fail = "tick count";
    }
    if( ulTimerExpiries < ( MESSAGES * PRODUCER_TICKS ) / TIMER_TICKS - 1 )
    {
        fail = "timer";
    }
    if( ulBusyCount == 0 )
    {
        fail = "busy task never ran";
    }
    if( uxTaskGetStackHighWaterMark( NULL ) < 16 )
    {
        fail = "stack";
    }

    /* The static protection of crt0.S: the code is read only and nothing but the code executes. */
    {
        volatile uint32_t ulLocal = 0;
        uint32_t ulCfg, ulFirstWord = *( volatile uint32_t * ) vBusyTask;   /* reading the code is allowed */
        void * pvHeap = pvPortMalloc( 16 );
        uint32_t ulStoreData = ulTryStore( &ulLocal ), ulStoreCode = ulTryStore( ( volatile uint32_t * ) vBusyTask );
        uint32_t ulExecHeap = ulTryJump( pvHeap ), ulExecStack = ulTryJump( ( void * ) &ulLocal );

        __asm volatile ( "csrr %0, pmpcfg0" : "=r" ( ulCfg ) );
        print_line( "prot store data ", ulStoreData );    /* 0: allowed */
        print_line( "prot store code ", ulStoreCode );    /* 7: store access fault */
        print_line( "prot exec heap ", ulExecHeap );      /* 1: instruction access fault */
        print_line( "prot exec stack ", ulExecStack );    /* 1 */
        if( ulCfg != 0x008B8D00 || ulFirstWord == 0 || ulStoreData != 0 || ulStoreCode != 7 || ulExecHeap != 1 || ulExecStack != 1 )
        {
            fail = "protection";
        }
        vPortFree( pvHeap );
    }

    xSemaphoreTake( xUartMutex, portMAX_DELAY );
    if( fail )
    {
        uart_puts( "FREERTOS FAIL " );
        uart_puts( fail );
        uart_putc( '\n' );
    }
    else
    {
        uart_puts( "FREERTOS OK\n" );
    }
    xSemaphoreGive( xUartMutex );

    vTaskSuspend( NULL );
}

/* The protection checks: each access must fault with the cause the PMP gives, and the task goes on. */
static uint32_t ulTryStore( volatile uint32_t * p )
{
    ulFaultCause = 0;
    ulExpectFault = 1;
    __asm volatile ( ".option push\n .option norvc\n sw zero, 0(%0)\n .option pop" ::"r" ( p ) : "memory" );
    ulExpectFault = 0;
    return ulFaultCause;
}

static uint32_t ulTryJump( void * p )
{
    ulFaultCause = 0;
    ulExpectFault = 1;
    ( ( void ( * )( void ) )p )();
    ulExpectFault = 0;
    return ulFaultCause;
}

static void vTimerCallback( TimerHandle_t xTimer )
{
    ( void ) xTimer;
    ulTimerExpiries++;
}

int main( void )
{
    xQueue = xQueueCreate( 4, sizeof( uint32_t ) );
    xUartMutex = xSemaphoreCreateMutex();
    TimerHandle_t xTimer = xTimerCreate( "tmr", TIMER_TICKS, pdTRUE, NULL, vTimerCallback );

    uart_puts( "FreeRTOS " tskKERNEL_VERSION_NUMBER "\n" );

    if( xQueue && xUartMutex && xTimer &&
        xTaskCreate( vBusyTask, "busy", configMINIMAL_STACK_SIZE, NULL, 1, NULL ) == pdPASS &&
        xTaskCreate( vProducerTask, "prod", configMINIMAL_STACK_SIZE, NULL, 2, NULL ) == pdPASS &&
        xTaskCreate( vConsumerTask, "cons", configMINIMAL_STACK_SIZE, NULL, 3, NULL ) == pdPASS &&
        xTimerStart( xTimer, 0 ) == pdPASS )
    {
        vTaskStartScheduler();
    }

    uart_puts( "FREERTOS FAIL start\n" );
    for( ; ; )
    {
    }
}

void vAssertCalled( const char * pcFile, int iLine )
{
    const char * name = pcFile;

    for( const char * p = pcFile; *p; p++ )
    {
        if( *p == '/' )
        {
            name = p + 1;
        }
    }

    portDISABLE_INTERRUPTS();
    uart_puts( "FREERTOS FAIL assert " );
    uart_puts( name );
    uart_putc( ':' );
    uart_putu( ( uint32_t ) iLine );
    uart_putc( '\n' );
    for( ; ; )
    {
    }
}

void vApplicationMallocFailedHook( void )
{
    uart_puts( "FREERTOS FAIL malloc\n" );
    portDISABLE_INTERRUPTS();
    for( ; ; )
    {
    }
}

void vApplicationStackOverflowHook( TaskHandle_t xTask, char * pcTaskName )
{
    ( void ) xTask;
    uart_puts( "FREERTOS FAIL stack overflow in " );
    uart_puts( pcTaskName );
    uart_putc( '\n' );
    portDISABLE_INTERRUPTS();
    for( ; ; )
    {
    }
}

/* An exception the demo provoked (ulExpectFault) returns to the task; any other: print mcause and stop. */
void freertos_risc_v_application_exception_handler( uintptr_t mcause )
{
    if( ulExpectFault )
    {
        uintptr_t * pxFrame = *( uintptr_t ** ) pxCurrentTCB;   /* [0] mepc, [1] mstatus, [2] ra */

        ulFaultCause = mcause;
        if( mcause == 1 )
        {
            pxFrame[ 0 ] = pxFrame[ 2 ];    /* instruction access fault: go back to the caller of the jump */
        }
        return;                              /* a faulting store: mepc already points past it */
    }

    uart_puts( "FREERTOS FAIL exception " );
    uart_putu( ( uint32_t ) mcause );
    uart_putc( '\n' );
    for( ; ; )
    {
    }
}

void freertos_risc_v_application_interrupt_handler( uintptr_t mcause )
{
    uart_puts( "FREERTOS FAIL interrupt " );
    uart_putu( ( uint32_t ) mcause );
    uart_putc( '\n' );
    for( ; ; )
    {
    }
}
