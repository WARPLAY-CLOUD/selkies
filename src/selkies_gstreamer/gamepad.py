# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import asyncio
import os
import struct
import socket
import time
from queue import Queue
from input_event_codes import *
from signal import (
    signal,
    SIGINT,
)

import logging
logger = logging.getLogger("selkies_gamepad")
logger.setLevel(logging.INFO)

STANDARD_XPAD_CONFIG = {
    # Browser detects xpad as 4 axes 17 button controller.
    # Linux xpad has 11 buttons and 8 axes.

    "name": "Selkies Controller",
    "btn_map": [
        BTN_A,      # 0
        BTN_B,      # 1
        BTN_X,      # 2
        BTN_Y,      # 3
        BTN_TL,     # 4
        BTN_TR,     # 5
        BTN_SELECT, # 6
        BTN_START,  # 7
        BTN_MODE,   # 8
        BTN_THUMBL, # 9
        BTN_THUMBR  # 10
    ],
    "axes_map": [
        ABS_X,      # 0
        ABS_Y,      # 1
        ABS_Z,      # 2
        ABS_RX,     # 3
        ABS_RY,     # 4
        ABS_RZ,     # 5
        ABS_HAT0X,  # 6
        ABS_HAT0Y   # 7
    ],


    # Input mapping from javascript:
    #   Axis 0: Left thumbstick X
    #   Axis 1: Left thumbstick Y
    #   Axis 2: Right thumbstick X
    #   Axis 3: Right thumbstick Y
    #   Button 0: A
    #   Button 1: B
    #   Button 2: X
    #   Button 3: Y
    #   Button 4: L1
    #   Button 5: R1
    #   Button 6: L2 (abs)
    #   Button 7: R2 (abs)
    #   Button 8: Select
    #   Button 9: Start
    #   Button 10: L3
    #   Button 11: R3
    #   Button 12: DPad Up
    #   Button 13: DPad Down
    #   Button 14: DPad Left
    #   Button 15: DPad Right
    #   Button 16: Xbox Button
    "mapping": {
        # Remap some buttons to axes
        "axes_to_btn": {
            2: (6,),     # ABS_Z to L2
            5: (7,),     # ABS_RZ to R2
            6: (15, 14), # ABS_HAT0X to DPad Left and DPad Right
            7: (13, 12)  # ABS_HAT0Y to DPad Down and DPad Up
        },
        # Remap axis, done in conjunction with axes_to_btn_map
        "axes": {
            2: 3, # Right Thumbstick X to ABS_RX
            3: 4, # Right Thumbstick Y to ABS_RY
        },
        # Because some buttons are remapped to axis, remap the other buttons to match target mapping.
        "btns": {
            8: 6,    # Select to BTN_SELECT
            9: 7,    # Start to BTN_START
            10: 9,   # L3 to BTN_THUMBL
            11: 10,  # R2 to BTN_THUMBR
            16: 8    # BTN_MODE
        },
        # Treat triggers as full range single axes
        "trigger_axes": [
            2, # ABS_Z
            5  # ABS_RZ
        ]
    }
}

# Vendor and product IDs to configs.
XPAD_CONFIG_MAP = {
    ("045e", "0b12"): STANDARD_XPAD_CONFIG,   # Xbox Series S/X
}

# From /usr/include/linux/joystick.h
JS_EVENT_BUTTON = 0x01
JS_EVENT_AXIS = 0x02

# Max num of buttons and axes
MAX_BTNS = 512
MAX_AXES = 64

# Range for axis values
ABS_MIN = -32767
ABS_MAX = 32767

# Joystick event struct
# https://www.kernel.org/doc/Documentation/input/joystick-api.txt
# struct js_event {
#    __u32 time;     /* event timestamp in milliseconds */
#    __s16 value;    /* value */
#    __u8 type;      /* event type */
#    __u8 number;    /* axis/button number */
# };

def get_btn_event(btn_num, btn_val):
    ts = int((time.time() * 1000) % 1000000000)

    # see js_event struct definition above.
    # https://docs.python.org/3/library/struct.html
    struct_format = 'IhBB'
    event = struct.pack(struct_format, ts, btn_val,
                        JS_EVENT_BUTTON, btn_num)

    logger.debug(struct.unpack(struct_format, event))

    return event


def get_axis_event(axis_num, axis_val):
    ts = int((time.time() * 1000) % 1000000000)

    # see js_event struct definition above.
    # https://docs.python.org/3/library/struct.html
    struct_format = 'IhBB'
    event = struct.pack(struct_format, ts, axis_val,
                        JS_EVENT_AXIS, axis_num)

    logger.debug(struct.unpack(struct_format, event))

    return event

def detect_gamepad_config(name):
    # TODO switch mapping based on name.
    return STANDARD_XPAD_CONFIG

def get_num_btns_for_mapping(cfg):
    num_mapped_btns = len(
        [i for j in cfg["axes_to_btn_map"].values() for i in j])
    return len(cfg["btn_map"]) + num_mapped_btns


def get_num_axes_for_mapping(cfg):
    return len(cfg["axes_map"])


def normalize_axis_val(val):
    return round(ABS_MIN + ((val+1) * (ABS_MAX - ABS_MIN)) / 2)


def normalize_trigger_val(val):
    return round(val * (ABS_MAX - ABS_MIN)) + ABS_MIN


def normalize_axis_val_from_255(val):
    """Normalize axis value from [0, 255] range to [-32767, 32767] range.
    
    Args:
        val: Axis value in range [0, 255] from frontend
        
    Returns:
        Normalized value in range [-32767, 32767]
    """
    # Преобразовать [0, 255] в [-32767, 32767]
    # val 0 -> -32767, val 127/128 -> 0, val 255 -> 32767
    return round(ABS_MIN + (val * (ABS_MAX - ABS_MIN)) / 255)


class SelkiesGamepad:
    def __init__(self, socket_path):
        self.socket_path = socket_path

        # Gamepad input mapper instance
        # created when calling set_config()
        self.mapper = None
        self.name = None

        # socket server
        self.server = None

        # Joystick config, set dynamically.
        self.config = None

        # Map of client file descriptors to sockets.
        self.clients = {}

        # queue of events to send.
        self.events = Queue()

        # flag indicating instance running.
        self.running = False
    
    def set_config(self, name, num_btns, num_axes):
        self.name = name
        self.config = detect_gamepad_config(name)
        self.mapper = GamepadMapper(self.config, name, num_btns, num_axes)
        
        # Send config to any clients that are already connected
        if self.clients:
            logger.info("Sending config to %d already connected clients" % len(self.clients))
            for client in list(self.clients.values()):
                # Create task to send config asynchronously
                asyncio.create_task(self.__send_config_to_client(client))

    def __make_config(self):
        '''
        Build config message to be sent to new clients.
        Requires that self.config has been set first.
        '''
        if not self.config:
            logger.error("could not make js config because it has not yet been set.")
            return None

        num_btns = len(self.config["btn_map"])
        num_axes = len(self.config["axes_map"])

        # zero fill array to max length.
        btn_map = [i for i in self.config["btn_map"]]
        axes_map = [i for i in self.config["axes_map"]]

        btn_map[num_btns:MAX_BTNS] = [0 for i in range(num_btns, MAX_BTNS)]
        axes_map[num_axes:MAX_AXES] = [0 for i in range(num_axes, MAX_AXES)]

        struct_fmt = "255sHH%dH%dB" % (MAX_BTNS, MAX_AXES)
        data = struct.pack(struct_fmt,
                           self.config["name"].encode(),
                           num_btns,
                           num_axes,
                           *btn_map,
                           *axes_map
                           )
        return data

    async def __send_events(self):
        events_processed = 0
        last_status_log_time = time.time()
        while self.running:
            if self.events.empty():
                await asyncio.sleep(0.001)
                # Log status every 5 seconds when idle
                current_time = time.time()
                if current_time - last_status_log_time >= 5.0:
                    logger.debug("Gamepad server status: queue_size=0, clients=%d, running=%s" % 
                                (len(self.clients), self.running))
                    last_status_log_time = current_time
                continue
            while self.running and not self.events.empty():
                queue_size = self.events.qsize()
                event = self.events.get()
                events_processed += 1
                logger.debug("Processing event #%d, queue_size=%d, clients=%d" % 
                            (events_processed, queue_size, len(self.clients)))
                await self.send_event(event)
                # Log status every 100 events
                if events_processed % 100 == 0:
                    logger.info("Processed %d events, current queue_size=%d, clients=%d" % 
                               (events_processed, self.events.qsize(), len(self.clients)))

    def send_btn(self, btn_num, btn_val):
        if not self.mapper:
            logger.warning("failed to send js button event because mapper was not set")
            return
        event = self.mapper.get_mapped_btn(btn_num, btn_val)
        if event is not None:
            self.events.put(event)

    def send_axis(self, axis_num, axis_val):
        if not self.mapper:
            logger.warning("failed to send js axis event because mapper was not set")
            return
        event = self.mapper.get_mapped_axis(axis_num, axis_val)
        if event is not None:
            queue_size_before = self.events.qsize()
            self.events.put(event)
            queue_size_after = self.events.qsize()
            logger.debug("Added axis event (axis=%d, val=%d) to queue: size %d -> %d" % 
                        (axis_num, axis_val, queue_size_before, queue_size_after))
        else:
            logger.warning("Failed to create axis event for axis=%d, val=%d (mapper returned None)" % 
                          (axis_num, axis_val))

    async def send_event(self, event):
        if len(self.clients) < 1:
            logger.debug("No clients connected, dropping event (size: %d bytes)" % len(event))
            return

        closed_clients = []
        loop = asyncio.get_event_loop()
        # Create a copy of client list to avoid modification during iteration
        client_fds = list(self.clients.keys())
        event_size = len(event)
        logger.debug("Sending event (size: %d bytes) to %d client(s)" % (event_size, len(client_fds)))
        
        for fd in client_fds:
            try:
                client = self.clients.get(fd)
                if client is None:
                    # Client was already removed
                    logger.debug("Client %d was already removed from clients dict" % fd)
                    continue
                logger.debug("Sending event to client with fd: %d (total clients: %d)" % (fd, len(self.clients)))
                # Use sock_sendall for non-blocking sockets
                await loop.sock_sendall(client, event)
                logger.debug("Successfully sent event to client %d" % fd)
            except (BrokenPipeError, ConnectionResetError, OSError) as e:
                logger.warning("Client %d disconnected during event send: %s (remaining clients: %d)" % 
                              (fd, e, len(self.clients) - 1))
                closed_clients.append(fd)
                try:
                    if client:
                        client.close()
                except:
                    pass
            except Exception as e:
                logger.error("Unexpected error sending event to client %d: %s (remaining clients: %d)" % 
                            (fd, e, len(self.clients) - 1), exc_info=True)
                # Mark client for removal on unexpected errors
                closed_clients.append(fd)
                try:
                    if client:
                        client.close()
                except:
                    pass

        # Safely remove closed clients
        if closed_clients:
            logger.info("Removing %d disconnected client(s): %s (remaining: %d)" % 
                       (len(closed_clients), closed_clients, len(self.clients) - len(closed_clients)))
        for fd in closed_clients:
            try:
                if fd in self.clients:
                    del self.clients[fd]
            except Exception as e:
                logger.error("Error removing client %d from clients dict: %s" % (fd, e))

    async def setup_client(self, client):
        try:
            fd = client.fileno()
            logger.info("Setting up client with fd: %d" % fd)
            
            # If config is not ready yet, client is already in self.clients dict
            # and will receive config when set_config is called
            if not self.config:
                logger.info("Config not ready yet, client %d will receive config when available" % fd)
                return
            
            await self.__send_config_to_client(client)
        except Exception as e:
            logger.error("Error in setup_client (fd: %d): %s" % (
                client.fileno() if client else None, e), exc_info=True)
            # Re-raise to let caller handle cleanup
            raise

    async def __send_config_to_client(self, client):
        """Send configuration to a connected client"""
        try:
            fd = client.fileno()
            logger.info("Sending config to client with fd: %d" % fd)
            config_data = self.__make_config()
            if not config_data:
                logger.warning("No config data available for client %d" % fd)
                return
            # Use sock_sendall for non-blocking sockets
            loop = asyncio.get_event_loop()
            await loop.sock_sendall(client, config_data)
            await asyncio.sleep(0.5)
            # Send zero values for all buttons and axis.
            if self.config:
                for btn_num in range(len(self.config["btn_map"])):
                    self.send_btn(btn_num, 0)
                for axis_num in range(len(self.config["axes_map"])):
                    self.send_axis(axis_num, 0)
        except (BrokenPipeError, ConnectionResetError, OSError) as e:
            fd = client.fileno()
            if fd in self.clients:
                del self.clients[fd]
            try:
                client.close()
            except:
                pass
            logger.info("Client disconnected during config send: %s" % e)
        except Exception as e:
            logger.error("Unexpected error sending config to client (fd: %d): %s" % (
                client.fileno() if client else None, e), exc_info=True)
            # Clean up client on unexpected error
            try:
                fd = client.fileno()
                if fd in self.clients:
                    del self.clients[fd]
                client.close()
            except:
                pass
            raise

    def _create_socket(self):
        """Synchronously create and bind socket so it's ready for connections"""
        try:
            os.unlink(self.socket_path)
        except OSError:
            if os.path.exists(self.socket_path):
                raise

        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.socket_path)
        self.server.listen(1)
        self.server.setblocking(False)

        logger.info('Socket created and bound at %s' % self.socket_path)

    async def run_server(self):
        # Create socket if not already created
        if self.server is None:
            self._create_socket()

        logger.info('Listening for connections on %s' % self.socket_path)

        # start task to process event queue.
        asyncio.create_task(self.__send_events())

        self.running = True
        server_start_time = time.time()
        last_status_log_time = time.time()
        try:
            while self.running:
                try:
                    client, _ = await asyncio.wait_for(
                        asyncio.get_event_loop().sock_accept(self.server), timeout=1)
                except asyncio.TimeoutError:
                    # Log server status every 30 seconds
                    current_time = time.time()
                    if current_time - last_status_log_time >= 30.0:
                        uptime = current_time - server_start_time
                        logger.info("Gamepad server status: uptime=%.1fs, clients=%d, queue_size=%d, running=%s" % 
                                   (uptime, len(self.clients), self.events.qsize(), self.running))
                        last_status_log_time = current_time
                    continue
                except Exception as e:
                    logger.error("Error accepting client connection: %s" % e, exc_info=True)
                    continue

                # Handle client connection with error handling to prevent server crash
                try:
                    fd = client.fileno()
                    logger.info("Client connected with fd: %d (total clients: %d)" % (fd, len(self.clients) + 1))

                    # Set client socket to non-blocking mode for async operations
                    client.setblocking(False)

                    # Add client to dictionary first (setup_client may need it)
                    self.clients[fd] = client
                    logger.debug("Added client %d to clients dict (total: %d)" % (fd, len(self.clients)))

                    # Send client the joystick configuration
                    await self.setup_client(client)
                    logger.debug("Successfully set up client %d" % fd)
                except Exception as e:
                    logger.error("Error handling client connection (fd: %d): %s (remaining clients: %d)" % (
                        client.fileno() if client else None, e, len(self.clients)), exc_info=True)
                    # Clean up failed client
                    try:
                        if client:
                            fd = client.fileno()
                            if fd in self.clients:
                                del self.clients[fd]
                            client.close()
                            logger.debug("Cleaned up failed client %d" % fd)
                    except Exception as cleanup_error:
                        logger.error("Error during cleanup of failed client: %s" % cleanup_error, exc_info=True)
                    # Continue serving other clients
                    continue
        finally:
            if self.server:
                self.server.close()
            try:
                os.unlink(self.socket_path)
            except:
                pass
        
        logger.info("Stopped gamepad socket server for %s" % self.socket_path)

    def stop_server(self):
        self.running = False
        self.server.close()
        try:
            os.unlink(self.socket_path)
        except:
            pass

class GamepadMapper:
    def __init__(self, config, name, num_btns, num_axes):
        self.config = config
        self.input_name = name
        self.input_num_btns = num_btns
        self.input_num_axes = num_axes
    
    def get_mapped_btn(self, btn_num, btn_val):
        '''
        return either a button or axis event based on mapping. 
        '''

        # Check to see if button is mapped to an axis
        axis_num = None
        axis_sign = 1
        for axis, mapping in self.config["mapping"]["axes_to_btn"].items():
            if btn_num in mapping:
                axis_num = axis
                if len(mapping) > 1:
                    axis_sign = 1 if mapping[0] == btn_num else -1
                break

        if axis_num is not None:
            # Remap button to axis
            # Normalize for input between -1 and 1
            axis_val = normalize_axis_val(btn_val*axis_sign)

            if axis_num in self.config["mapping"]["trigger_axes"]:
                # Normalize to full range for input between 0 and 1.
                axis_val = normalize_trigger_val(btn_val)
            
            return get_axis_event(axis_num, axis_val)

        # Perform button mapping.
        mapped_btn = self.config["mapping"]["btns"].get(btn_num, btn_num)
        if mapped_btn >= len(self.config["btn_map"]):
            logger.error("cannot send button num %d, max num buttons is %d" % (
                mapped_btn, len(self.config["btn_map"]) - 1))
            return None
        
        return get_btn_event(mapped_btn, int(btn_val))

    def get_mapped_axis(self, axis_num, axis_val):
        mapped_axis = self.config["mapping"]["axes"].get(axis_num, axis_num)
        if mapped_axis >= len(self.config["axes_map"]):
            logger.error("cannot send axis %d, max axis num is %d" %
                         (mapped_axis, len(self.config["axes_map"]) - 1))
            return None

        # Normalize axis value from [0, 255] range (from frontend) to [-32767, 32767] range
        normalized_val = normalize_axis_val_from_255(axis_val)
        logger.debug("Axis %d: input=%d (0-255) -> normalized=%d (-32767 to 32767)" % 
                     (axis_num, axis_val, normalized_val))
        return get_axis_event(mapped_axis, normalized_val)
