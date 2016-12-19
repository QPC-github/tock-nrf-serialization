/* Copyright (c) 2013 Nordic Semiconductor. All Rights Reserved.
 *
 * The information contained herein is property of Nordic Semiconductor ASA.
 * Terms and conditions of usage are described in detail in NORDIC
 * SEMICONDUCTOR STANDARD SOFTWARE LICENSE AGREEMENT.
 *
 * Licensees are granted free, non-transferable use of the information. NO
 * WARRANTY of ANY KIND is provided. This heading must NOT be removed from
 * the file.
 *
 */

/**@file
 *
 * @defgroup ble_sdk_app_connectivity_main main.c
 * @{
 * @ingroup ble_sdk_app_connectivity
 *
 * @brief BLE Connectivity application.
 */

#include <stdbool.h>
#include <string.h>
#include "nrf_sdm.h"
#include "nrf_soc.h"
#include "app_error.h"
#include "app_scheduler.h"
#include "app_gpiote.h"
#include "softdevice_handler.h"
#include "ser_hal_transport.h"
#include "ser_conn_handlers.h"

#include "ser_phy_debug_comm.h"

#include "boards.h"
#include "led.h"
// #define DEBUG_LEDS

// Generic Tock platform ID
#define PLATFORM_ID 0x14

// make errors evident to anyone watching
// void app_error_handler(uint32_t error_code, uint32_t line_num, const uint8_t* p_file_name) {
void app_error_fault_handler(uint32_t id, uint32_t pc, uint32_t info) {
    led_init(LED_0);

    // this is the same blink pattern that panic! in Tock uses
    volatile int i;
    while (1) {
        led_on(LED_0);
        for (i=0; i<500000; i++);

        led_off(LED_0);
        for (i=0; i<50000; i++);

        led_on(LED_0);
        for (i=0; i<500000; i++);

        led_off(LED_0);
        for (i=0; i<250000; i++);
    }
}

// Configure the MAC address of the device based on the config values and
// what is stored in the flash.
bool ble_address_set () {
    uint32_t err_code;

    // Set the MAC address of the device
    // Highest priority is address from flash if available
    // Next is is the address supplied by user in ble_config
    // Finally, Nordic assigned random value is used as last choice
    ble_gap_addr_t gap_addr;

    // get BLE address from Flash
    uint8_t* _ble_address = (uint8_t*)BLEADDR_FLASH_LOCATION;
    if (_ble_address[1] == 0xFF && _ble_address[0] == 0xFF) {
        // No user-defined address stored in flash

        // New address is a combination of Michigan OUI and Platform ID
        uint8_t new_mac_addr[6] = {0x00, 0x00, PLATFORM_ID, 0xe5, 0x98, 0xc0};

        // Set the new BLE address with the Michigan OUI, Platform ID, and
        //  bottom two octets from the original gap address
        // Get the current original address
        sd_ble_gap_address_get(&gap_addr);
        memcpy(gap_addr.addr+2, new_mac_addr+2, sizeof(gap_addr.addr)-2);
    } else {
        // User-defined address stored in flash

        // Set the new BLE address with the user-defined address
        memcpy(gap_addr.addr, _ble_address, 6);
    }

    gap_addr.addr_type = BLE_GAP_ADDR_TYPE_PUBLIC;
    err_code = sd_ble_gap_address_set(BLE_GAP_ADDR_CYCLE_MODE_NONE, &gap_addr);
    // not an error if it failed, we'll just try again later
    //APP_ERROR_CHECK(err_code);

    // did it succeed this time?
    return (err_code == NRF_SUCCESS);
}

#if TOCK_BOARD == storm
// The Firestorm board does not have a GPIO connected to the !RESET line on
// the nRF. To work around this, we use a GPIO and an interrupt, and when
// that GPIO is triggered the nRF resets.

// Need this for the app_gpiote library
app_gpiote_user_id_t gpiote_user;

void interrupt_handler (uint32_t pins_l2h, uint32_t pins_h2l) {
    if (pins_h2l & (1 << SW_RESET_PIN)) {
        // Reset the nRF51822
        NVIC_SystemReset();
    }
}
#endif

/**@brief Main function of the connectivity application. */
int main(void)
{
    uint32_t err_code = NRF_SUCCESS;

    /* Force constant latency mode to control SPI slave timing */
    NRF_POWER->TASKS_CONSTLAT = 1;

    /* Initialize scheduler queue. */
    APP_SCHED_INIT(SER_CONN_SCHED_MAX_EVENT_DATA_SIZE, SER_CONN_SCHED_QUEUE_SIZE);
    /* Initialize SoftDevice.
     * SoftDevice Event IRQ is not scheduled but immediately copies BLE events to the application
     * scheduler queue */
    nrf_clock_lf_cfg_t clock_lf_cfg = NRF_CLOCK_LFCLKSRC;
    SOFTDEVICE_HANDLER_INIT(&clock_lf_cfg, NULL);

    /* Subscribe for BLE events. */
    err_code = softdevice_ble_evt_handler_set(ser_conn_ble_event_handle);
    APP_ERROR_CHECK(err_code);

    /* Open serialization HAL Transport layer and subscribe for HAL Transport events. */
    err_code = ser_hal_transport_open(ser_conn_hal_transport_event_handle);
    APP_ERROR_CHECK(err_code);

#ifdef DEBUG_LEDS
    led_init(LED_0);
    led_off(LED_0);
#endif

#if TOCK_BOARD == storm
    // For 1 users of GPIOTE
    APP_GPIOTE_INIT(1);

    // Register us as one user
    app_gpiote_user_register(&gpiote_user,
                             1<<SW_RESET_PIN,   // Which pins we want the interrupt for low to high
                             1<<SW_RESET_PIN,   // Which pins we want the interrupt for high to low
                             interrupt_handler);

    // Ready to go!
    app_gpiote_user_enable(gpiote_user);
#endif

    /* Enter main loop. */
    bool first_event_received = false;
    bool address_set = false;
    for (;;)
    {
        /* Process SoftDevice events. */
        app_sched_execute();

        /* Process received packets.
         * We can NOT add received packets as events to the application scheduler queue because
         * received packets have to be processed before SoftDevice events but the scheduler queue
         * does not have priorities. */
        err_code = ser_conn_rx_process();
        APP_ERROR_CHECK(err_code);

        /* Set BLE address
         * This cannot be run until sd_ble_enable has been called, which is
         * always the first tranmission to be sent. So this will just try
         * setting the address repeatedly until it succeeds (which will occur
         * 10 byte receptions in, after sd_ble_enable comes across the wire*/
        if (first_event_received && !address_set) {
            address_set = ble_address_set();
        }

#ifdef DEBUG_LEDS
        led_toggle(LED_0);
#endif

        /* Sleep waiting for an application event. */
        err_code = sd_app_evt_wait();
        APP_ERROR_CHECK(err_code);
        first_event_received = true;
    }
}
/** @} */
