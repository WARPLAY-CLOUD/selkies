# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import asyncio
import os
import struct
import socket
import time
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
    """Create a joystick axis event.
    
    Args:
        axis_num: Axis number (0-based)
        axis_val: Axis value in range [-32767, 32767] (signed 16-bit)
        
    Returns:
        Packed event data
    """
    # Convert to int to ensure proper type for struct.pack
    # struct format 'h' requires integer type
    if not isinstance(axis_val, (int, float)):
        logger.error('[%s] Axis value has invalid type: %s (expected int or float) for axis %d' % 
                    (time.strftime('%H:%M:%S'), type(axis_val).__name__, axis_num))
        axis_val = int(axis_val) if axis_val is not None else 0
    
    axis_val = int(round(axis_val))  # Ensure integer value
    
    # Validate axis value is within signed 16-bit range
    # struct format 'h' supports -32768 to 32767
    if axis_val < -32768 or axis_val > 32767:
        logger.error('[%s] Axis value %d is out of range [-32768, 32767] for axis %d, clamping' % 
                    (time.strftime('%H:%M:%S'), axis_val, axis_num))
        axis_val = max(-32768, min(32767, axis_val))
    
    ts = int((time.time() * 1000) % 1000000000)

    # see js_event struct definition above.
    # https://docs.python.org/3/library/struct.html
    # Format: I (unsigned int, 32-bit) for timestamp
    #         h (signed short, 16-bit) for value - supports -32768 to 32767
    #         B (unsigned char, 8-bit) for type
    #         B (unsigned char, 8-bit) for number
    struct_format = 'IhBB'
    
    try:
    event = struct.pack(struct_format, ts, axis_val,
                        JS_EVENT_AXIS, axis_num)
        logger.debug('[%s] Packed axis event: axis=%d, value=%d (range: -32768 to 32767)' % 
                    (time.strftime('%H:%M:%S'), axis_num, axis_val))
    except struct.error as e:
        logger.error('[%s] Failed to pack axis event: axis=%d, value=%d, error=%s' % 
                    (time.strftime('%H:%M:%S'), axis_num, axis_val, e))
        raise

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
            - 0 = стик полностью влево/вниз (браузер: -1)
            - 128 = стик в центре (браузер: 0) 
            - 255 = стик полностью вправо/вверх (браузер: 1)
        
    Returns:
        Normalized value in range [-32767, 32767], clamped to valid range
        - Центр стика (val=128) должен давать 0
    """
    # Преобразовать [0, 255] в [-32767, 32767]
    # Фронтенд: val = ((browser_val + 1) / 2) * 255
    # где browser_val ∈ [-1, 1], центр = 0 → val = 128
    # 
    # Правильная формула: val 128 (центр) → 0
    # normalized = (val - 128) * (32767 / 128)
    # Или: normalized = (val - 128) * 256 (приблизительно)
    
    # Точная формула: центр стика (val=128) должен давать 0
    # Линейная интерполяция с точным соответствием границам:
    # val = 0 → -32767, val = 128 → 0, val = 255 → 32767
    # 
    # Формула: normalized = (val / 255) * (ABS_MAX - ABS_MIN) + ABS_MIN - ABS_MAX
    # Или проще: normalized = (val - 128) * (65534 / 255)
    # Но для точности используем интерполяцию с учетом центра:
    
    # Используем точную линейную интерполяцию:
    # Для val [0, 128]: normalized = val * (-32767 / 128)
    # Для val [128, 255]: normalized = (val - 128) * (32767 / 127)
    
    center = 128
    if val <= center:
        # Слева от центра: [0, 128] → [-32767, 0]
        # Линейная интерполяция от центра: normalized = (val - 128) * scale
        # val=0 → -32767, val=128 → 0
        # scale = 32767 / 128 = 256.015625
        normalized = round((val - center) * (ABS_MAX / center))
    else:
        # Справа от центра: [129, 255] → [1, 32767]
        # Линейная интерполяция от центра: normalized = (val - 128) * scale
        # val=129 → 1, val=255 → 32767
        # scale = 32767 / 127 = 258.007874
        normalized = round((val - center) * (ABS_MAX / (255 - center)))
    
    # Clamp to valid range to prevent overflow/underflow
    # struct format 'h' supports -32768 to 32767, but we use -32767 to 32767
    if normalized < ABS_MIN:
        logger.warning('[%s] Normalized axis value %d is below minimum %d, clamping' % 
                      (time.strftime('%H:%M:%S'), normalized, ABS_MIN))
        normalized = ABS_MIN
    elif normalized > ABS_MAX:
        logger.warning('[%s] Normalized axis value %d is above maximum %d, clamping' % 
                      (time.strftime('%H:%M:%S'), normalized, ABS_MAX))
        normalized = ABS_MAX
    
    return normalized


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

        # queue of events to send - use async queue to prevent blocking
        self.events = asyncio.Queue(maxsize=1000)
        self.max_queue_size = 1000  # Maximum queue size to prevent overflow

        # flag indicating instance running.
        self.running = False
    
    def set_config(self, name, num_btns, num_axes):
        logger.info('[%s] Setting config for gamepad: name="%s", buttons=%d, axes=%d' % 
                   (time.strftime('%H:%M:%S'), name, num_btns, num_axes))
        self.name = name
        self.config = detect_gamepad_config(name)
        logger.debug('[%s] Gamepad config detected, creating mapper...' % time.strftime('%H:%M:%S'))
        self.mapper = GamepadMapper(self.config, name, num_btns, num_axes)
        logger.info('[%s] Config set successfully, mapper created' % time.strftime('%H:%M:%S'))
        
        # Send config to any clients that are already connected
        if self.clients:
            logger.info('[%s] Sending config to %d already connected clients' % 
                       (time.strftime('%H:%M:%S'), len(self.clients)))
            for client in list(self.clients.values()):
                fd = client.fileno() if client else None
                logger.debug('[%s] Creating async task to send config to client %d' % 
                            (time.strftime('%H:%M:%S'), fd))
                # Create task to send config asynchronously
                asyncio.create_task(self.__send_config_to_client(client))
        else:
            logger.debug('[%s] No clients connected yet, config will be sent when client connects' % 
                        time.strftime('%H:%M:%S'))

    def __make_config(self):
        '''
        Build config message to be sent to new clients.
        Requires that self.config has been set first.
        '''
        if not self.config:
            logger.error('[%s] Could not make js config because it has not yet been set.' % 
                        time.strftime('%H:%M:%S'))
            return None

        num_btns = len(self.config["btn_map"])
        num_axes = len(self.config["axes_map"])
        logger.debug('[%s] Building config: buttons=%d, axes=%d' % 
                    (time.strftime('%H:%M:%S'), num_btns, num_axes))

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
        logger.debug('[%s] Config data built: %d bytes' % (time.strftime('%H:%M:%S'), len(data)))
        return data

    async def __send_events(self):
        events_processed = 0
        last_status_log_time = time.time()
        consecutive_errors = 0
        last_queue_check_time = time.time()
        
        logger.info('[%s] Event processing loop started' % time.strftime('%H:%M:%S'))
        
        try:
        while self.running:
                try:
                    if self.events.qsize() == 0:
                await asyncio.sleep(0.001)
                        # Log status every 5 seconds when idle
                        current_time = time.time()
                        if current_time - last_status_log_time >= 5.0:
                            logger.debug('[%s] Gamepad server status: queue_size=0, clients=%d, running=%s' % 
                                        (time.strftime('%H:%M:%S'), len(self.clients), self.running))
                            last_status_log_time = current_time
                        continue
                    
                    # If queue is very large, process more aggressively
                    queue_size = self.events.qsize()
                    if queue_size > 500:
                        logger.warning('[%s] Queue size is very large (%d), processing aggressively' % 
                                      (time.strftime('%H:%M:%S'), queue_size))
                        # Reduce sleep time when queue is large
                        await asyncio.sleep(0)  # Yield immediately
                    
                    # Log warning if queue is not empty but not being processed
                    current_time = time.time()
                    queue_size = self.events.qsize()
                    if current_time - last_queue_check_time >= 10.0 and queue_size > 0:
                        logger.error('[%s] Queue not empty (size=%d) but events not being processed for >10s! '
                                    'This indicates the processing loop may be stuck.' % 
                                    (time.strftime('%H:%M:%S'), queue_size))
                        # Log more diagnostic info
                        logger.error('[%s] Diagnostic: running=%s, events_processed=%d, clients=%d' % 
                                    (time.strftime('%H:%M:%S'), self.running, events_processed, len(self.clients)))
                        last_queue_check_time = current_time
                        # Try to force yield
                        await asyncio.sleep(0)
                    
                    # Process events in batch for better performance when queue is large
                    queue_size_start = self.events.qsize()
                    batch_size = 10 if queue_size_start > 100 else 1
                    events_in_batch = 0
                    
                    # Track when we last processed an event
                    last_event_processed_time = time.time()
                    loop_entry_time = time.time()
                    
                    logger.debug('[%s] Entering event processing loop: queue_size=%d, batch_size=%d' % 
                                (time.strftime('%H:%M:%S'), queue_size_start, batch_size))
                    
                    while self.running and self.events.qsize() > 0:
                        try:
                            # Check if we're stuck (no event processed in last 5 seconds)
                            current_time = time.time()
                            if current_time - last_event_processed_time > 5.0:
                                queue_size = self.events.qsize()
                                logger.error('[%s] Event processing appears stuck! Queue size: %d, '
                                           'no events processed in last %.1fs' % 
                                           (time.strftime('%H:%M:%S'), queue_size, 
                                            current_time - last_event_processed_time))
                                # Try to recover by skipping current event
                                try:
                                    self.events.get_nowait()  # Skip potentially problematic event
                                except asyncio.QueueEmpty:
                                    pass
                                except Exception:
                                    pass
                                last_event_processed_time = current_time
                                # Yield to allow other tasks to run
                                await asyncio.sleep(0.1)
                                continue
                            
                            queue_size = self.events.qsize()
                            event = await self.events.get()
                            events_processed += 1
                            events_in_batch += 1
                            consecutive_errors = 0  # Reset error counter on success
                            last_event_processed_time = current_time  # Update processing time
                            
                            # Reduce logging when queue is large to improve performance
                            if queue_size < 100:
                                logger.debug('[%s] Processing event #%d, queue_size=%d, clients=%d' % 
                                            (time.strftime('%H:%M:%S'), events_processed, queue_size, len(self.clients)))
                            
                            # Add timeout for event sending to prevent infinite hangs
                            send_start_time = time.time()
                            try:
                                await asyncio.wait_for(self.send_event(event), timeout=2.0)
                                send_duration = time.time() - send_start_time
                                if send_duration > 0.5:
                                    logger.warning('[%s] Event send took %.3fs (slow!)' % 
                                                  (time.strftime('%H:%M:%S'), send_duration))
                            except asyncio.TimeoutError:
                                logger.error('[%s] Timeout sending event #%d (took >2s, skipping)' % 
                                            (time.strftime('%H:%M:%S'), events_processed))
                                # Skip this event and continue
                                continue
                            
                            # Log status every 100 events or when batch is complete
                            if events_processed % 100 == 0 or (events_in_batch >= batch_size and queue_size > 100):
                                loop_duration = time.time() - loop_entry_time
                                logger.info('[%s] Processed %d events, current queue_size=%d, clients=%d, loop_time=%.2fs' % 
                                           (time.strftime('%H:%M:%S'), events_processed, self.events.qsize(), len(self.clients), loop_duration))
                                events_in_batch = 0
                                loop_entry_time = time.time()  # Reset for next batch
                                # Yield control briefly to prevent blocking
                                await asyncio.sleep(0)
                        
                        # Log if we exit the inner loop
                        if self.events.qsize() > 0 and self.running:
                            logger.debug('[%s] Exiting inner event loop but queue not empty (size=%d), will retry' % 
                                        (time.strftime('%H:%M:%S'), self.events.qsize()))
                        
                        except Exception as e:
                            consecutive_errors += 1
                            logger.error('[%s] Error processing event #%d: %s (consecutive errors: %d)' % 
                                        (time.strftime('%H:%M:%S'), events_processed + 1, e, consecutive_errors), exc_info=True)
                            
                            # If too many consecutive errors, log warning but continue
                            if consecutive_errors >= 10:
                                logger.error('[%s] Too many consecutive errors (%d), but continuing event processing' % 
                                            (time.strftime('%H:%M:%S'), consecutive_errors))
                                consecutive_errors = 0  # Reset to avoid log spam
                            
                            # Continue processing next event even if current one failed
                            continue
                
                except Exception as e:
                    logger.error('[%s] Error in event processing loop: %s' % 
                                (time.strftime('%H:%M:%S'), e), exc_info=True)
                    await asyncio.sleep(0.1)  # Brief pause before retrying
                continue
        
        except Exception as e:
            logger.critical('[%s] Fatal error in event processing loop, stopping: %s' % 
                           (time.strftime('%H:%M:%S'), e), exc_info=True)
            self.running = False
        
        logger.warning('[%s] Event processing loop stopped (processed %d events total)' % 
                      (time.strftime('%H:%M:%S'), events_processed))

    def send_btn(self, btn_num, btn_val):
        if not self.mapper:
            logger.warning('[%s] Failed to send js button event because mapper was not set (btn=%d, val=%d)' % 
                          (time.strftime('%H:%M:%S'), btn_num, btn_val))
            return
        try:
        event = self.mapper.get_mapped_btn(btn_num, btn_val)
        if event is not None:
                queue_size_before = self.events.qsize()
                
                # Prevent queue overflow: drop oldest events if queue is full
                dropped_events = 0
                while self.events.qsize() >= self.max_queue_size:
                    try:
                        self.events.get_nowait()  # Drop oldest event
                        dropped_events += 1
                    except asyncio.QueueEmpty:
                        # Queue is empty (shouldn't happen, but handle it)
                        break
                    except Exception as e:
                        logger.error('[%s] Error dropping old events from queue: %s' % 
                                    (time.strftime('%H:%M:%S'), e))
                        break
                
                if dropped_events > 0:
                    logger.warning('[%s] Queue overflow: dropped %d old events, adding new button event (btn=%d, val=%d)' % 
                                  (time.strftime('%H:%M:%S'), dropped_events, btn_num, btn_val))
                
                self.events.put_nowait(event)
                queue_size_after = self.events.qsize()
                
                # Log warning if queue is getting large
                if queue_size_after > self.max_queue_size * 0.7:
                    logger.warning('[%s] Queue size is large: %d/%d events (btn=%d, val=%d)' % 
                                  (time.strftime('%H:%M:%S'), queue_size_after, self.max_queue_size, btn_num, btn_val))
                
                logger.debug('[%s] Added button event (btn=%d, val=%d) to queue: size %d -> %d' % 
                            (time.strftime('%H:%M:%S'), btn_num, btn_val, queue_size_before - dropped_events, queue_size_after))
        except Exception as e:
            logger.error('[%s] Error in send_btn (btn=%d, val=%d): %s' % 
                        (time.strftime('%H:%M:%S'), btn_num, btn_val, e), exc_info=True)

    def send_axis(self, axis_num, axis_val):
        if not self.mapper:
            logger.warning('[%s] Failed to send js axis event because mapper was not set (axis=%d, val=%d)' % 
                          (time.strftime('%H:%M:%S'), axis_num, axis_val))
            return
        try:
        event = self.mapper.get_mapped_axis(axis_num, axis_val)
        if event is not None:
                queue_size_before = self.events.qsize()
                
                # Prevent queue overflow: drop oldest events if queue is full
                dropped_events = 0
                while self.events.qsize() >= self.max_queue_size:
                    try:
                        self.events.get_nowait()  # Drop oldest event
                        dropped_events += 1
                    except asyncio.QueueEmpty:
                        # Queue is empty (shouldn't happen, but handle it)
                        break
                    except Exception as e:
                        logger.error('[%s] Error dropping old events from queue: %s' % 
                                    (time.strftime('%H:%M:%S'), e))
                        break
                
                if dropped_events > 0:
                    logger.warning('[%s] Queue overflow: dropped %d old events, adding new axis event (axis=%d, val=%d)' % 
                                  (time.strftime('%H:%M:%S'), dropped_events, axis_num, axis_val))
                
                self.events.put_nowait(event)
                queue_size_after = self.events.qsize()
                
                # Log warning if queue is getting large
                if queue_size_after > self.max_queue_size * 0.7:
                    logger.warning('[%s] Queue size is large: %d/%d events (axis=%d, val=%d)' % 
                                  (time.strftime('%H:%M:%S'), queue_size_after, self.max_queue_size, axis_num, axis_val))
                
                logger.debug('[%s] Added axis event (axis=%d, val=%d) to queue: size %d -> %d' % 
                            (time.strftime('%H:%M:%S'), axis_num, axis_val, queue_size_before - dropped_events, queue_size_after))
            else:
                logger.warning('[%s] Failed to create axis event for axis=%d, val=%d (mapper returned None)' % 
                              (time.strftime('%H:%M:%S'), axis_num, axis_val))
        except Exception as e:
            logger.error('[%s] Error in send_axis (axis=%d, val=%d): %s' % 
                        (time.strftime('%H:%M:%S'), axis_num, axis_val, e), exc_info=True)

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
                            logger.debug('[%s] Sending event to client with fd: %d (total clients: %d)' % 
                                        (time.strftime('%H:%M:%S'), fd, len(self.clients)))
                # Use sock_sendall for non-blocking sockets with timeout
                try:
                    await asyncio.wait_for(loop.sock_sendall(client, event), timeout=1.0)
                    logger.debug('[%s] Successfully sent event to client %d' % (time.strftime('%H:%M:%S'), fd))
                except asyncio.TimeoutError:
                    logger.error('[%s] Timeout sending event to client %d (socket may be blocked)' % 
                                (time.strftime('%H:%M:%S'), fd))
                    raise
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
            logger.info('[%s] Setting up client with fd: %d' % (time.strftime('%H:%M:%S'), fd))
            
            # If config is not ready yet, client is already in self.clients dict
            # and will receive config when set_config is called
            if not self.config:
                logger.warning('[%s] Config not ready yet, client %d will receive config when available' % 
                              (time.strftime('%H:%M:%S'), fd))
                return
            
            logger.debug('[%s] Config is ready, proceeding with config send to client %d' % 
                        (time.strftime('%H:%M:%S'), fd))
            await self.__send_config_to_client(client)
        except Exception as e:
            logger.error('[%s] Error in setup_client (fd: %d): %s' % 
                        (time.strftime('%H:%M:%S'), client.fileno() if client else None, e), exc_info=True)
            # Re-raise to let caller handle cleanup
            raise

    async def __send_config_to_client(self, client):
        """Send configuration to a connected client"""
        try:
            fd = client.fileno()
            logger.info('[%s] Preparing to send config to client with fd: %d' % 
                       (time.strftime('%H:%M:%S'), fd))
            config_start_time = time.time()
            config_data = self.__make_config()
            if not config_data:
                logger.warning('[%s] No config data available for client %d' % 
                              (time.strftime('%H:%M:%S'), fd))
                return
            config_size = len(config_data)
            logger.info('[%s] Config data prepared: %d bytes for client %d' % 
                       (time.strftime('%H:%M:%S'), config_size, fd))
            
            # Use sock_sendall for non-blocking sockets
            loop = asyncio.get_event_loop()
            send_start_time = time.time()
            logger.debug('[%s] Sending config (%d bytes) to client %d...' % 
                        (time.strftime('%H:%M:%S'), config_size, fd))
            await loop.sock_sendall(client, config_data)
            send_duration = time.time() - send_start_time
            logger.info('[%s] Config sent to client %d in %.3fs (%d bytes)' % 
                       (time.strftime('%H:%M:%S'), fd, send_duration, config_size))
            
            logger.debug('[%s] Waiting 0.5s before sending zero values to client %d...' % 
                        (time.strftime('%H:%M:%S'), fd))
            await asyncio.sleep(0.5)
            
            # Send zero values for all buttons and axis.
            if self.config:
                num_btns = len(self.config["btn_map"])
                num_axes = len(self.config["axes_map"])
                logger.debug('[%s] Sending zero values: %d buttons, %d axes to client %d' % 
                            (time.strftime('%H:%M:%S'), num_btns, num_axes, fd))
                zero_start_time = time.time()
                for btn_num in range(num_btns):
                self.send_btn(btn_num, 0)
                for axis_num in range(num_axes):
                self.send_axis(axis_num, 0)
                zero_duration = time.time() - zero_start_time
                logger.debug('[%s] Zero values sent to client %d in %.3fs' % 
                            (time.strftime('%H:%M:%S'), fd, zero_duration))
            
            total_config_duration = time.time() - config_start_time
            logger.info('[%s] Config fully sent to client %d (total time: %.3fs)' % 
                       (time.strftime('%H:%M:%S'), fd, total_config_duration))
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
        logger.info('[%s] Creating socket at %s...' % (time.strftime('%H:%M:%S'), self.socket_path))
        try:
            if os.path.exists(self.socket_path):
                logger.debug('[%s] Removing existing socket file: %s' % 
                            (time.strftime('%H:%M:%S'), self.socket_path))
            os.unlink(self.socket_path)
                logger.debug('[%s] Existing socket file removed' % time.strftime('%H:%M:%S'))
        except OSError as e:
            if os.path.exists(self.socket_path):
                logger.error('[%s] Failed to remove existing socket file: %s' % 
                            (time.strftime('%H:%M:%S'), e))
                raise

        logger.debug('[%s] Creating UNIX domain socket...' % time.strftime('%H:%M:%S'))
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        logger.debug('[%s] Binding socket to %s...' % (time.strftime('%H:%M:%S'), self.socket_path))
        self.server.bind(self.socket_path)
        logger.debug('[%s] Setting socket to listen mode...' % time.strftime('%H:%M:%S'))
        self.server.listen(1)
        logger.debug('[%s] Setting socket to non-blocking mode...' % time.strftime('%H:%M:%S'))
        self.server.setblocking(False)

        logger.info('[%s] Socket created and bound at %s' % (time.strftime('%H:%M:%S'), self.socket_path))

    async def run_server(self):
        # Create socket if not already created
        if self.server is None:
            self._create_socket()

        logger.info('[%s] Starting gamepad server, listening for connections on %s' % 
                   (time.strftime('%H:%M:%S'), self.socket_path))

        # start task to process event queue.
        asyncio.create_task(self.__send_events())

        self.running = True
        server_start_time = time.time()
        last_status_log_time = time.time()
        connection_attempts = 0
        successful_connections = 0
        try:
            while self.running:
                try:
                    logger.debug('[%s] Waiting for client connection (attempt #%d)...' % 
                                (time.strftime('%H:%M:%S'), connection_attempts + 1))
                    connection_attempts += 1
                    accept_start_time = time.time()
                    client, addr = await asyncio.wait_for(
                        asyncio.get_event_loop().sock_accept(self.server), timeout=1)
                    accept_duration = time.time() - accept_start_time
                    logger.info('[%s] Client connection accepted in %.3fs (attempt #%d)' % 
                               (time.strftime('%H:%M:%S'), accept_duration, connection_attempts))
                except asyncio.TimeoutError:
                    # Log server status every 30 seconds
                    current_time = time.time()
                    if current_time - last_status_log_time >= 30.0:
                        uptime = current_time - server_start_time
                        logger.info('[%s] Gamepad server status: uptime=%.1fs, connection_attempts=%d, '
                                   'successful_connections=%d, clients=%d, queue_size=%d, running=%s' % 
                                   (time.strftime('%H:%M:%S'), uptime, connection_attempts, 
                                    successful_connections, len(self.clients), self.events.qsize(), self.running))
                        last_status_log_time = current_time
                    continue
                except Exception as e:
                    logger.error('[%s] Error accepting client connection (attempt #%d): %s' % 
                                (time.strftime('%H:%M:%S'), connection_attempts, e), exc_info=True)
                    continue

                # Handle client connection with error handling to prevent server crash
                connection_handle_start = time.time()
                try:
                fd = client.fileno()
                    successful_connections += 1
                    logger.info('[%s] Client connected with fd: %d (total clients: %d, successful: %d/%d)' % 
                               (time.strftime('%H:%M:%S'), fd, len(self.clients) + 1, 
                                successful_connections, connection_attempts))

                    # Set client socket to non-blocking mode for async operations
                    client.setblocking(False)
                    logger.debug('[%s] Set client %d to non-blocking mode' % 
                                (time.strftime('%H:%M:%S'), fd))

                    # Add client to dictionary first (setup_client may need it)
                    self.clients[fd] = client
                    logger.info('[%s] Added client %d to clients dict (total: %d)' % 
                               (time.strftime('%H:%M:%S'), fd, len(self.clients)))

                # Send client the joystick configuration
                    setup_start = time.time()
                await self.setup_client(client)
                    setup_duration = time.time() - setup_start
                    logger.info('[%s] Successfully set up client %d in %.3fs' % 
                               (time.strftime('%H:%M:%S'), fd, setup_duration))
                    
                    total_handle_duration = time.time() - connection_handle_start
                    logger.info('[%s] Client %d fully connected and ready (total setup time: %.3fs)' % 
                               (time.strftime('%H:%M:%S'), fd, total_handle_duration))
                except Exception as e:
                    logger.error('[%s] Error handling client connection (fd: %d): %s (remaining clients: %d)' % 
                                (time.strftime('%H:%M:%S'), client.fileno() if client else None, e, len(self.clients)), 
                                exc_info=True)
                    # Clean up failed client
                    try:
                        if client:
                            fd = client.fileno()
                            if fd in self.clients:
                                del self.clients[fd]
                                logger.info('[%s] Removed failed client %d from clients dict' % 
                                           (time.strftime('%H:%M:%S'), fd))
                            client.close()
                            logger.info('[%s] Closed socket for failed client %d' % 
                                       (time.strftime('%H:%M:%S'), fd))
                    except Exception as cleanup_error:
                        logger.error('[%s] Error during cleanup of failed client: %s' % 
                                    (time.strftime('%H:%M:%S'), cleanup_error), exc_info=True)
                    # Continue serving other clients
                    logger.info('[%s] Continuing to serve other clients after error' % 
                               time.strftime('%H:%M:%S'))
                    continue
        finally:
            logger.info('[%s] Gamepad server shutting down...' % time.strftime('%H:%M:%S'))
            if self.server:
                logger.debug('[%s] Closing server socket...' % time.strftime('%H:%M:%S'))
            self.server.close()
            try:
                logger.debug('[%s] Removing socket file: %s' % (time.strftime('%H:%M:%S'), self.socket_path))
                os.unlink(self.socket_path)
                logger.debug('[%s] Socket file removed' % time.strftime('%H:%M:%S'))
            except Exception as e:
                logger.warning('[%s] Error removing socket file: %s' % (time.strftime('%H:%M:%S'), e))
            logger.info('[%s] Stopped gamepad socket server for %s (clients: %d)' % 
                       (time.strftime('%H:%M:%S'), self.socket_path, len(self.clients)))

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
        # Validate input value is in expected range [0, 255]
        if axis_val < 0 or axis_val > 255:
            logger.warning('[%s] Axis %d input value %d is outside expected range [0, 255], clamping' % 
                          (time.strftime('%H:%M:%S'), axis_num, axis_val))
            axis_val = max(0, min(255, axis_val))
        
        mapped_axis = self.config["mapping"]["axes"].get(axis_num, axis_num)
        if mapped_axis >= len(self.config["axes_map"]):
            logger.error('[%s] Cannot send axis %d, max axis num is %d' %
                         (time.strftime('%H:%M:%S'), mapped_axis, len(self.config["axes_map"]) - 1))
            return None

        # Normalize axis value from [0, 255] range (from frontend) to [-32767, 32767] range
        normalized_val = normalize_axis_val_from_255(axis_val)
        logger.debug('[%s] Axis %d: input=%d (0-255) -> normalized=%d (-32767 to 32767), mapped_axis=%d' % 
                     (time.strftime('%H:%M:%S'), axis_num, axis_val, normalized_val, mapped_axis))
        
        try:
            event = get_axis_event(mapped_axis, normalized_val)
            return event
        except Exception as e:
            logger.error('[%s] Failed to create axis event for axis %d (mapped=%d) with value %d: %s' % 
                        (time.strftime('%H:%M:%S'), axis_num, mapped_axis, normalized_val, e), exc_info=True)
            return None
