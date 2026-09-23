/*
 * Stand-in for vitaSDK's psp2/touch.h (tools/vita-sim): the declarations
 * frontends/vita uses, with the SDK's names and layout.
 */
#ifndef _PSP2_TOUCH_H_
#define _PSP2_TOUCH_H_

#include <stdint.h>

#define SCE_TOUCH_MAX_REPORT 8

typedef enum SceTouchPortType {
	SCE_TOUCH_PORT_FRONT = 0,
	SCE_TOUCH_PORT_BACK = 1
} SceTouchPortType;

typedef enum SceTouchSamplingState {
	SCE_TOUCH_SAMPLING_STATE_STOP = 0,
	SCE_TOUCH_SAMPLING_STATE_START = 1
} SceTouchSamplingState;

typedef struct SceTouchReport {
	uint8_t id;
	uint8_t force;
	uint16_t x;
	uint16_t y;
	int8_t reserved[8];
	uint16_t info;
} SceTouchReport;

typedef struct SceTouchData {
	uint64_t timeStamp;
	uint32_t status;
	uint32_t reportNum;
	SceTouchReport report[SCE_TOUCH_MAX_REPORT];
} SceTouchData;

int sceTouchSetSamplingState(uint32_t port, SceTouchSamplingState state);
int sceTouchPeek(uint32_t port, SceTouchData *pData, uint32_t nBufs);

#endif
