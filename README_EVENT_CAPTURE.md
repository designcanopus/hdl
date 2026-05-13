# Event Capture System Guide

This document describes the event-based data capture system for the AD485x ADC on the ZedBoard.

---

## 1. System Architecture & Data Flow
The data follows a specific path from the analog pins to the Linux userspace:
1.  **Analog Input:** Signals enter the **AD485x ADC**.
2.  **FPGA Entry:** Data is deserialized by the `axi_ad485x` core.
3.  **Event Capture (BRAM):** The `util_event_capture` module stores data in a circular buffer (BRAM).
    *   **Pre-Trigger:** 2,500 samples are kept from *before* the trigger.
    *   **Post-Trigger:** 7,500 samples are captured *after* the trigger.
4.  **DMA Transfer:** Upon trigger completion, the logic replays the window to the **AXI DMAC**.
5.  **PS DDR Storage:** The DMA writes the 10,000-sample window into the **Processing System DDR Memory**.
6.  **Linux Access:** Kuiper Linux accesses this memory via the **IIO (Industrial I/O) Framework**.

---

## 2. Manual Verification
To manually verify that the hardware is capturing data correctly, use the following commands on the ZedBoard terminal:

**Capture a single event window:**
```bash
# This command will block until a hardware trigger occurs
iio_readdev -s 10000 iio:device1 > event.bin
```

**Inspect the raw values:**
```bash
# View the first 20 samples in decimal format (8 channels per row)
od -t d2 event.bin | head -n 20
```

---

## 3. Live Monitor Setup
To view events in real-time as they happen, use the custom Python monitoring system.

### A. The Web Viewer (`index.html`)
This file auto-refreshes the plot every 500ms.
```bash
cat <<EOF > index.html
<html>
<body style="background: #000; color: #0f0; text-align: center;">
    <h2>Live ADC Event Monitor</h2>
    <img id="image" src="event_plot.png" style="width: 90%;">
    <script>
        setInterval(function(){
            document.getElementById('image').src = 'event_plot.png?t=' + new Date().getTime();
        }, 500); 
    </script>
</body>
</html>
EOF
```

### B. The Monitor Script (`live_monitor.py`)
This script loops: waiting for a trigger, updating the plot, and repeating.
```python
import os, time, numpy as np, matplotlib.pyplot as plt

while True:
    try:
        # Wait for hardware trigger
        os.system("iio_readdev -s 10000 iio:device2 > live.bin")
        
        # Process and Plot
        data = np.fromfile("live.bin", dtype=np.int16).reshape(-1, 8)
        plt.clf()
        plt.plot(data[:, 0])
        plt.title(f"Event Captured at {time.strftime('%H:%M:%S')}")
        plt.savefig("event_plot.png")
        print(f"Update: Event at {time.strftime('%H:%M:%S')}")
    except KeyboardInterrupt: break
```

---

## 4. Running the Live Scope
1.  **Start the Web Server:** `python3 -m http.server 8000 &`
2.  **Start the Monitor:** `python3 live_monitor.py`
3.  **View:** Open `http://<zedboard_ip>:8000` in any web browser.

---

## 5. Tuning & Configuration
*   **Threshold:** Controlled via the `ad485x_threshold_gpio` AXI register.
*   **Window Size:** Currently fixed at **10,000 samples** in the HDL parameters.
*   **Interface:** Only event data is streamed; zero-padding is disabled to save DMA bandwidth.
