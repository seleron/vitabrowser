/* Host stand-in for vitaSDK's <psp2/ctrl.h>: the subset frontends/vita uses.
 * Values and layout copied from ~/vitasdk/arm-vita-eabi/include/psp2common/
 * ctrl.h (vita-headers ebc8f4f). See tools/vita-stub/vita2d.h. */
#ifndef _PSP2_CTRL_H_
#define _PSP2_CTRL_H_

#include <stdint.h>

typedef enum SceCtrlButtons {
	SCE_CTRL_SELECT   = 0x00000001,
	SCE_CTRL_START    = 0x00000008,
	SCE_CTRL_UP       = 0x00000010,
	SCE_CTRL_RIGHT    = 0x00000020,
	SCE_CTRL_DOWN     = 0x00000040,
	SCE_CTRL_LEFT     = 0x00000080,
	SCE_CTRL_LTRIGGER = 0x00000100,
	SCE_CTRL_RTRIGGER = 0x00000200,
	SCE_CTRL_TRIANGLE = 0x00001000,
	SCE_CTRL_CIRCLE   = 0x00002000,
	SCE_CTRL_CROSS    = 0x00004000,
	SCE_CTRL_SQUARE   = 0x00008000
} SceCtrlButtons;

typedef enum SceCtrlPadInputMode {
	SCE_CTRL_MODE_DIGITAL = 0,
	SCE_CTRL_MODE_ANALOG = 1
} SceCtrlPadInputMode;

typedef struct SceCtrlData {
	uint64_t timeStamp;
	unsigned int buttons;
	unsigned char lx;
	unsigned char ly;
	unsigned char rx;
	unsigned char ry;
	uint8_t up, right, down, left, lt, rt, l1, r1;
	uint8_t triangle, circle, cross, square;
	uint8_t reserved[4];
} SceCtrlData;

int sceCtrlSetSamplingMode(SceCtrlPadInputMode mode);
int sceCtrlPeekBufferPositive(int port, SceCtrlData *pad_data, int count);

#endif
