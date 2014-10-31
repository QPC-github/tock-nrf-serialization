/*
 * Copyright (c) 2014 The Regents of the University  of California.
 * All rights reserved."
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * - Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in the
 *   documentation and/or other materials provided with the
 *   distribution.
 * - Neither the name of the copyright holders nor the names of
 *   its contributors may be used to endorse or promote products derived
 *   from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL
 * THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 */

#include <IPDispatch.h>
#include <lib6lowpan/lib6lowpan.h>
#include <lib6lowpan/ip.h>
#include <lib6lowpan/ip.h>
#include <printf.h>
#include "sensys_structs.h"

#define DATA_TX_PERIOD 2500L

module SensysDemoP
{
    uses
    {
        interface Boot;
        interface SplitControl as RadioControl;
        interface UDP as DataSock;
        interface UDP as BLESock;
        interface GeneralIO as Led;
        interface Timer<TMilli> as Timer;
        interface SplitControl as SensorControl;
        interface FlashAttr;
        interface RootControl;
        interface FSIlluminance;
        interface FSAccelerometer;
        interface ForwardingTable;
        interface StdControl as RplControl;
        interface StdControl as ScrufflesCtl;

        //BLE Central
        interface BleCentral;

        //BLE Peripheral
        interface BlePeripheral;
        interface BleLocalService as Observer;
        interface BleLocalChar as ObserverC;
    }
}
implementation
{
    struct sockaddr_in6 data_dest;
    struct sockaddr_in6 ble_dest;
    struct sockaddr_in6 nhop;
    bool do_data_tx;
    uint32_t liveness_idx;
    bool isBLEPacket;
    ble_data_t ble_packet;
    uint8_t adv [32];
    uint8_t adv_len;

    bool shouldBeRoot()
    {
        uint8_t key [10];
        uint8_t val [65];
        uint8_t val_len;
        error_t e;

        e = call FlashAttr.getAttr(1, key, val, &val_len);
        if (e != SUCCESS)
        {
            printf ("failed to get attr\n");
        }
        return (e == SUCCESS && val_len == 1 && (val[0] == 1 || val[0] == '1'));
    }
    void loadDataTarget()
    {
        uint8_t key [10];
        uint8_t val [65];
        uint8_t val_len;
        error_t e;

        e = call FlashAttr.getAttr(2, key, val, &val_len);
        if (e != SUCCESS || val_len < 4)
        {
            printf ("failed to get data target\n");
            do_data_tx = FALSE;
            return;
        }
        val[val_len] = 0;
        printf("sending data to %s\n", val);
        inet_pton6(val, &data_dest.sin6_addr);
        inet_pton6(val, &ble_dest.sin6_addr);
        do_data_tx = TRUE;
    }

    event void Boot.booted()
    {
        liveness_idx = 0;
        data_dest.sin6_port = htons(4410);
        ble_dest.sin6_port = htons(4411);
        isBLEPacket = FALSE;
        call Timer.startPeriodic(DATA_TX_PERIOD);
        call DataSock.bind(4410);
        call BLESock.bind(4411);
        call Led.makeOutput();
        call Led.set();
        call SensorControl.start();

        if (shouldBeRoot())
        {
            printf("Node configured to be root\n");
            printf("\033[31;1mNOT ACTIVATING WATCHDOG\n\033[0m");
            call RootControl.setRoot();
           // call BlePeripheral.initialize();
        }
        else
        {
            printf("Node is not DODAG root\n");
            call ScrufflesCtl.start();
            call BleCentral.initialize();
        }
        loadDataTarget();
        call RadioControl.start();

        call BlePeripheral.initialize();
    }

    // BLE CENTRAL
    event void BleCentral.ready()
    {
        call BleCentral.scan();
    }


    async event void BleCentral.advReceived(uint8_t* addr,
        uint8_t *data, uint8_t dlen, uint8_t rssi) {
        int i;
        printf("ADV: %02x", addr[5]);
        for (i = 4; i >= 0; i--) {
          printf(":%02x", addr[i]);
        }
        printf(" ");
        atomic
        {
            if (adv_len < 32 && dlen == 24 && data[dlen-2] == 'l')
            {
                adv[adv_len] = data[dlen-1];
                adv_len++;
            }
            else if (adv_len < 32)
            {   //Not a squall, record anyway
                printf("not squall: len=%d\n",dlen);
               // adv[adv_len] = 0xFF;
               // adv_len++;
            }
        }
        for (i = 0; i < dlen; i++) {
          printf("%02x", data[i]);
        }
        printf(" rssi: %d\n", rssi);
      }

    // BLE PERIPHERAL
    event void BlePeripheral.ready()
    {
        call Observer.configure();
        call BlePeripheral.startAdvertising();
    }
    event void ObserverC.onWrite(uint16_t len, uint8_t const *value) {}
    event void ObserverC.indicateConfirmed() {}
    event void ObserverC.timeout() {}
    event void BlePeripheral.connected()
    {
        printf("[[ BLE PERIPHERAL CONNECTED ]]\n");
    }

    event void BlePeripheral.disconnected()
    {
        printf("[[ BLE PERIPHERAL DISCONNECTED ]]\n");
        call BlePeripheral.startAdvertising();
    }

    event void BlePeripheral.advertisingTimeout()
    {
        call BlePeripheral.startAdvertising();
    }


    event void RadioControl.startDone(error_t e) {}
    event void RadioControl.stopDone(error_t e) {}
    event void SensorControl.startDone(error_t e) {}
    event void SensorControl.stopDone(error_t e) {}

    void print_dstruct(node_data_t *v, uint16_t from)
    {
        int i, mx, ln;
        uint8_t buffer[1024]; //BECAUSE I HAVE SO MUCH RAM!!
        ln = snprintf(buffer, 1022,
        "DSTRUCT<<{\n"
            "\t\"from\" : \"%04x\",\n"
            "\t\"acc_x\": %d,\n"
            "\t\"acc_y\": %d,\n"
            "\t\"acc_z\": %d,\n"
            "\t\"mag_x\": %d,\n"
            "\t\"mag_y\": %d,\n"
            "\t\"mag_z\": %d,\n"
            "\t\"lux\"  : %d,\n"
            "\t\"ftlen\": %d,\n"
            "\t\"ft\":[\n"
        ,from, v->acc_x, v->acc_y, v->acc_z, v->mag_x, v->mag_y, v->mag_z, v->lux, v->ftable_len);
        mx = v->ftable_len;
        if (mx > 8) mx = 8; 
       // for (i = 0; i<mx; i++)
       // {
       //     ln += snprintf(buffer+ln, 1022-ln,
       //         "\t\t{\"r\":\"%04x\",\"p\":%d,\"via\":\"X::%04x\"}\n", v->fdest[i], v->pfxlen[i], v->fnhop[i]);
       //
       // }
        ln += snprintf(buffer+ln, 1022-ln, "\t]\n}>>\n");
        atomic{
            printf(buffer);
        }
#if 0

        printf("  ACC_X: %d\n",v->acc_x);
        printf("  ACC_Y: %d\n",v->acc_y);
        printf("  ACC_Z: %d\n",v->acc_z);
        printf("  MAG_X: %d\n",v->mag_x);
        printf("  MAG_Y: %d\n",v->mag_y);
        printf("  MAG_Z: %d\n",v->mag_z);
        printf("    LUX: %d\n",v->lux);
        printf("  FTLEN: %d\n",v->ftable_len);
        mx = v->ftable_len;
        if (mx > 8) mx = 8;
        for (i = 0; i<mx; i++)
        {
            printf("    - [%d]: X::%04x/%d via X::%04x\n", i, v->fdest[i], v->pfxlen[i], v->fnhop[i]);
        }
#endif
    }

    void print_blestruct(ble_data_t *v, uint16_t from)
    {
        int i, ln;
        uint8_t buffer[1024];
        ln = snprintf(buffer, 1022, "BSTRUCT<<{\n\t\"ids\":[");
        for (i = 0; i < v->len; i++)
        {
            if ( i!= 0 )
                ln += snprintf(buffer + ln, 1022-ln, ",");
            ln += snprintf(buffer + ln, 1022-ln, "\"%02d\"",v->idents[i]);
        }
        ln += snprintf(buffer + ln, 1022-ln, "],\n");
        ln += snprintf(buffer + ln, 1022-ln, "\t\"from\":\"0x%04x\"\n}>>\n", from);
        atomic
        {
            printf(buffer);
        }
    }

    event void BLESock.recvfrom(struct sockaddr_in6 *from, void *data,
                                uint16_t len, struct ip6_metadata *meta)
    {
        ble_data_t *rx;
        uint16_t from_serial;
        from_serial = from->sin6_addr.s6_addr[14];
        from_serial = (from_serial << 8) + from->sin6_addr.s6_addr[15];
        if (len == sizeof(ble_data_t))
        {   
            printf("\033[32;1m");
            printf("Got a BLE struct from 0x%04x\n", from_serial);
            rx = (ble_data_t*) data;
            print_blestruct(rx, from_serial);
            printf("\033[0m\n");
        }   
        else
        {   
            printf("Got random BLE data\n");
        } 
    }

    
    
    event void DataSock.recvfrom(struct sockaddr_in6 *from, void *data,
                             uint16_t len, struct ip6_metadata *meta)
    {
        node_data_t *rx;
        uint16_t from_serial;
        from_serial = from->sin6_addr.s6_addr[14];
        from_serial = (from_serial << 8) + from->sin6_addr.s6_addr[15];
        if (len == sizeof(node_data_t))
        {
            struct sockaddr_in6 scruffles_addr;
            scruffles_addr = *from;
            scruffles_addr.sin6_port = htons(0xFF5);
            liveness_idx++;
            call DataSock.sendto(&scruffles_addr, &liveness_idx, 4);    
            printf("\033[32;1m");
            rx = (node_data_t*) data;
            print_dstruct(rx, from_serial);
            printf("\033[0m\n");
        }
        else if (len == sizeof(ble_data_t))
        {
            printf("fuckit, just treating it as BLE\n");
            printf("\033[32;1m");
            printf("Got a BLE struct from 0x%04x\n", from_serial);
            print_blestruct((ble_data_t*) data, from_serial);
            printf("\033[0m\n");
        }
    }

    node_data_t tx;
    event void Timer.fired()
    {
        struct route_entry *ft;
        int i;
        int max_size;
        int valid_size;

        if (!do_data_tx) return;
        call Led.toggle();

        if (isBLEPacket)
        {
            atomic
            {
                ble_packet.len = adv_len;
                for (i=0;i<adv_len;i++)
                {
                    ble_packet.idents[i] = adv[i];
                }
                adv_len = 0;
            }
            call DataSock.sendto(&ble_dest, &ble_packet, sizeof(ble_data_t));
        }
        else
        {
            tx.acc_x = call FSAccelerometer.getAccelX();
            tx.acc_y = call FSAccelerometer.getAccelY();
            tx.acc_z = call FSAccelerometer.getAccelZ();
            tx.mag_x = call FSAccelerometer.getMagnX();
            tx.mag_y = call FSAccelerometer.getMagnY();
            tx.mag_z = call FSAccelerometer.getMagnZ();
            tx.lux = (uint16_t) call FSIlluminance.getVisibleLux();
            ft = call ForwardingTable.getTable(&max_size);
            valid_size = 0;
            for (i = 0; i < max_size; i++)
            {
                if (!ft[i].valid) continue;
                if (valid_size < 8)
                {
                    struct in6_addr ad;
                    ad = ft[i].prefix;
                    tx.fdest[valid_size] = ((uint16_t)ad.s6_addr[14] << 8) + ad.s6_addr[15];
                    ad = ft[i].next_hop;
                    tx.fnhop[valid_size] = ((uint16_t)ad.s6_addr[14] << 8) + ad.s6_addr[15];
                    tx.pfxlen[valid_size] = ft[i].prefixlen;
                }
                valid_size++;
            }
            tx.ftable_len = valid_size;
            call DataSock.sendto(&data_dest, &tx, sizeof(node_data_t));
        }
        isBLEPacket = !isBLEPacket;

    }



}
