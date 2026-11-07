/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * FreeRTOS configuration for asic_soc_rv32imac: 32 KiB of RAM shared by the code, the data, the heap
 * and the stacks, the CLINT's mtime and mtimecmp as the tick (mtime counts the CPU clock), no FPU. */
#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#define configCPU_CLOCK_HZ                  ( 18432000UL )     /* the board's oscillator */
#define configTICK_RATE_HZ                  ( ( TickType_t ) 1000 )
#define configMTIME_BASE_ADDRESS            ( 0x0200BFF8UL )   /* CLINT_BASE + 0xBFF8 */
#define configMTIMECMP_BASE_ADDRESS         ( 0x02004000UL )   /* CLINT_BASE + 0x4000 */

#define configUSE_PREEMPTION                1
#define configUSE_TIME_SLICING              1
#define configUSE_IDLE_HOOK                 0
#define configUSE_TICK_HOOK                 0
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 0
#define configMAX_PRIORITIES                5
#define configMINIMAL_STACK_SIZE            ( ( unsigned short ) 128 )   /* words */
#define configISR_STACK_SIZE_WORDS          128
#define configTOTAL_HEAP_SIZE               ( ( size_t ) ( 12 * 1024 ) )
#define configMAX_TASK_NAME_LEN             8
#define configUSE_16_BIT_TICKS              0
#define configIDLE_SHOULD_YIELD             1
#define configUSE_MUTEXES                   1
#define configUSE_RECURSIVE_MUTEXES         0
#define configUSE_COUNTING_SEMAPHORES       1
#define configQUEUE_REGISTRY_SIZE           0
#define configUSE_TRACE_FACILITY            0
#define configSUPPORT_STATIC_ALLOCATION     0
#define configSUPPORT_DYNAMIC_ALLOCATION    1
#define configCHECK_FOR_STACK_OVERFLOW      2
#define configUSE_MALLOC_FAILED_HOOK        1
#define configUSE_TIMERS                    1
#define configTIMER_TASK_PRIORITY           ( configMAX_PRIORITIES - 1 )
#define configTIMER_QUEUE_LENGTH            4
#define configTIMER_TASK_STACK_DEPTH        ( configMINIMAL_STACK_SIZE )

void vAssertCalled( const char * pcFile, int iLine );   /* main.c: prints the place and stops */
#define configASSERT( x )                   do { if( ( x ) == 0 ) { vAssertCalled( __FILE__, __LINE__ ); } } while( 0 )

#define INCLUDE_vTaskPrioritySet            0
#define INCLUDE_uxTaskPriorityGet           0
#define INCLUDE_vTaskDelete                 0
#define INCLUDE_vTaskSuspend                1
#define INCLUDE_vTaskDelayUntil             1
#define INCLUDE_vTaskDelay                  1
#define INCLUDE_xTaskGetSchedulerState      0
#define INCLUDE_uxTaskGetStackHighWaterMark 1
#define INCLUDE_xTimerPendFunctionCall      0

#endif /* FREERTOS_CONFIG_H */
