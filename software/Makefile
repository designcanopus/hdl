CROSS_COMPILE ?= arm-linux-gnueabihf-
CC = $(CROSS_COMPILE)gcc
CFLAGS ?= -O2 -Wall -Wextra -static
LDFLAGS = -pthread -static

TARGET = event_dma_capture
SRCS = event_dma_capture.c event_dma_hw.c event_dma_udp.c
OBJS = $(SRCS:.c=.o)
HEADERS = event_dma_capture.h event_dma_hw.h event_dma_udp.h

# Deployment defaults — override on the command line:
#   make deploy REMOTE_HOST=root@192.168.1.100 REMOTE_PATH=/home/root/
REMOTE_HOST ?= root@192.168.1.1
REMOTE_PATH ?= /home/root/

.PHONY: all clean deploy run

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS) $(LDFLAGS)

%.o: %.c $(HEADERS)
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(TARGET)

# Copy freshly built binary to the Zynq board over SSH.
# Usage: make deploy REMOTE_HOST=root@<board-ip>
deploy: $(TARGET)
	scp $(TARGET) $(REMOTE_HOST):$(REMOTE_PATH)

# Launch the Python visualizer (uses python3 to avoid 'python not found').
run:
	cd py-ae-visualizer && python3 -m ae_visualizer
