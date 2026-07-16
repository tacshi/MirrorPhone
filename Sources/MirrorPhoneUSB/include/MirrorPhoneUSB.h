#ifndef MOBILE_MIRROR_USB_H
#define MOBILE_MIRROR_USB_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*MMAndroidAccessoryDataCallback)(
    void *context,
    const uint8_t *bytes,
    size_t length);

typedef void (*MMAndroidAccessoryStatusCallback)(
    void *context,
    const char *status,
    bool connected);

typedef void *MMAndroidAccessoryHostRef;

MMAndroidAccessoryHostRef mm_android_accessory_host_create(
    void *context,
    MMAndroidAccessoryDataCallback data_callback,
    MMAndroidAccessoryStatusCallback status_callback);

void mm_android_accessory_host_start(MMAndroidAccessoryHostRef host);
void mm_android_accessory_host_stop(MMAndroidAccessoryHostRef host);
void mm_android_accessory_host_destroy(MMAndroidAccessoryHostRef host);

#ifdef __cplusplus
}
#endif

#endif
