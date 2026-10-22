// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Test vocabulary, independent of the DUT's permission/FSM wire encodings.
package multicore_observation;
    typedef enum logic [1:0] {OBS_INVALID, OBS_SHARED, OBS_MODIFIED, OBS_EXCLUSIVE} permission_t;
endpackage
