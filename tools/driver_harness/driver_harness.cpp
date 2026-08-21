#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <unistd.h>

#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static constexpr AudioObjectID kObjectID_PlugIn = kAudioObjectPlugInObject;
static constexpr AudioObjectID kObjectID_Device_Mic = 2;
static constexpr AudioObjectID kObjectID_Stream_Mic = 3;
static constexpr AudioObjectID kObjectID_Device_Sink = 4;
static constexpr AudioObjectID kObjectID_Stream_Sink = 5;
static constexpr Float64 kExpectedSampleRate = 48000.0;
static constexpr UInt32 kExpectedChannels = 2;
static constexpr UInt32 kClientID = 0xC011EC7u;
static constexpr UInt32 kGuardSize = 64;

static int gFailures = 0;
static int gPasses = 0;
static UInt32 gPropertiesChangedCalls = 0;

static const char* fourcc(UInt32 v) {
    static thread_local char s[16];
    char c[5] = { char((v >> 24) & 0xff), char((v >> 16) & 0xff), char((v >> 8) & 0xff), char(v & 0xff), 0 };
    for (int i = 0; i < 4; ++i) if (c[i] < 32 || c[i] > 126) c[i] = '.';
    std::snprintf(s, sizeof(s), "'%s'", c);
    return s;
}

static void pass(const char* fmt, ...) {
    ++gPasses;
    std::printf("PASS ");
    va_list ap; va_start(ap, fmt); std::vprintf(fmt, ap); va_end(ap);
    std::printf("\n");
}

static void fail(const char* fmt, ...) {
    ++gFailures;
    std::printf("FAIL ");
    va_list ap; va_start(ap, fmt); std::vprintf(fmt, ap); va_end(ap);
    std::printf("\n");
}

#define CHECK(cond, ...) do { if (cond) pass(__VA_ARGS__); else fail(__VA_ARGS__); } while (0)
#define REQUIRE(cond, ...) do { if (cond) { pass(__VA_ARGS__); } else { fail(__VA_ARGS__); return false; } } while (0)
#define REQUIRE_MAIN(cond, ...) do { if (cond) { pass(__VA_ARGS__); } else { fail(__VA_ARGS__); return 1; } } while (0)

static OSStatus HostPropertiesChanged(AudioServerPlugInHostRef, AudioObjectID, UInt32, const AudioObjectPropertyAddress*) {
    ++gPropertiesChangedCalls;
    return noErr;
}
static OSStatus HostCopyFromStorage(AudioServerPlugInHostRef, CFStringRef, CFPropertyListRef* outData) {
    if (outData) *outData = nullptr;
    return kAudioHardwareUnknownPropertyError;
}
static OSStatus HostWriteToStorage(AudioServerPlugInHostRef, CFStringRef, CFPropertyListRef) { return noErr; }
static OSStatus HostDeleteFromStorage(AudioServerPlugInHostRef, CFStringRef) { return noErr; }
static OSStatus HostRequestDeviceConfigurationChange(AudioServerPlugInHostRef, AudioObjectID, UInt64, void*) { return noErr; }

static AudioServerPlugInHostInterface gHost = {
    HostPropertiesChanged,
    HostCopyFromStorage,
    HostWriteToStorage,
    HostDeleteFromStorage,
    HostRequestDeviceConfigurationChange
};

struct Driver {
    AudioServerPlugInDriverRef ref = nullptr;
    AudioServerPlugInDriverInterface* iface = nullptr;
};

static bool same_cfstring(CFStringRef s, const char* expected) {
    if (!s) return false;
    char buf[256];
    return CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8) && std::strcmp(buf, expected) == 0;
}

struct PropResult {
    OSStatus status = noErr;
    UInt32 size = 0;
    std::vector<uint8_t> bytes;
};

static PropResult get_prop(Driver& d, AudioObjectID objectID, UInt32 selector, UInt32 scope = kAudioObjectPropertyScopeGlobal,
                           UInt32 element = kAudioObjectPropertyElementMain, UInt32 qualSize = 0, const void* qual = nullptr,
                           const char* label = nullptr) {
    AudioObjectPropertyAddress addr = { selector, scope, element };
    PropResult r;
    bool has = d.iface->HasProperty(d.ref, objectID, 0, &addr);
    CHECK(has, "HasProperty object=%u selector=%s scope=%s%s%s", objectID, fourcc(selector), fourcc(scope), label ? " " : "", label ? label : "");
    Boolean settable = true;
    OSStatus st = d.iface->IsPropertySettable(d.ref, objectID, 0, &addr, &settable);
    CHECK(st == noErr && !settable, "IsPropertySettable false object=%u selector=%s scope=%s status=%d", objectID, fourcc(selector), fourcc(scope), (int)st);
    st = d.iface->GetPropertyDataSize(d.ref, objectID, 0, &addr, qualSize, qual, &r.size);
    if (st != noErr) {
        fail("GetPropertyDataSize object=%u selector=%s scope=%s status=%d", objectID, fourcc(selector), fourcc(scope), (int)st);
        r.status = st;
        return r;
    }
    pass("GetPropertyDataSize object=%u selector=%s scope=%s size=%u", objectID, fourcc(selector), fourcc(scope), r.size);

    UInt32 capacity = r.size + kGuardSize;
    if (capacity == 0) capacity = kGuardSize;
    r.bytes.assign(capacity, 0xA5);
    UInt32 outSize = 0xDEADBEEF;
    st = d.iface->GetPropertyData(d.ref, objectID, 0, &addr, qualSize, qual, capacity, &outSize, r.bytes.data());
    r.status = st;
    if (st != noErr) {
        fail("GetPropertyData object=%u selector=%s scope=%s status=%d", objectID, fourcc(selector), fourcc(scope), (int)st);
        return r;
    }
    CHECK(outSize == r.size, "Size/data contract object=%u selector=%s scope=%s reported=%u data=%u", objectID, fourcc(selector), fourcc(scope), r.size, outSize);
    bool guardOK = true;
    for (UInt32 i = outSize; i < capacity; ++i) {
        if (r.bytes[i] != 0xA5) { guardOK = false; break; }
    }
    CHECK(guardOK, "Guard bytes untouched object=%u selector=%s scope=%s outSize=%u capacity=%u", objectID, fourcc(selector), fourcc(scope), outSize, capacity);
    return r;
}

static bool expect_unknown(Driver& d, AudioObjectID objectID) {
    AudioObjectPropertyAddress addr = { 'zzzz', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    uint8_t data[32];
    UInt32 outSize = 0;
    bool has = d.iface->HasProperty(d.ref, objectID, 0, &addr);
    OSStatus sizeStatus = d.iface->GetPropertyDataSize(d.ref, objectID, 0, &addr, 0, nullptr, &size);
    OSStatus dataStatus = d.iface->GetPropertyData(d.ref, objectID, 0, &addr, 0, nullptr, sizeof(data), &outSize, data);
    CHECK(!has, "Unknown selector HasProperty false object=%u", objectID);
    CHECK(sizeStatus == kAudioHardwareUnknownPropertyError, "Unknown selector GetPropertyDataSize returns unknown-property object=%u status=%d", objectID, (int)sizeStatus);
    CHECK(dataStatus == kAudioHardwareUnknownPropertyError, "Unknown selector GetPropertyData returns unknown-property object=%u status=%d", objectID, (int)dataStatus);
    return !has && sizeStatus == kAudioHardwareUnknownPropertyError && dataStatus == kAudioHardwareUnknownPropertyError;
}

static UInt32 read_u32(const PropResult& r) { UInt32 v = 0; if (r.bytes.size() >= sizeof(v)) std::memcpy(&v, r.bytes.data(), sizeof(v)); return v; }
static Float64 read_f64(const PropResult& r) { Float64 v = 0; if (r.bytes.size() >= sizeof(v)) std::memcpy(&v, r.bytes.data(), sizeof(v)); return v; }
static AudioObjectID read_oid(const PropResult& r) { AudioObjectID v = 0; if (r.bytes.size() >= sizeof(v)) std::memcpy(&v, r.bytes.data(), sizeof(v)); return v; }

static bool check_format(const AudioStreamBasicDescription& f, const char* label) {
    bool ok = true;
    if (std::fabs(f.mSampleRate - kExpectedSampleRate) > 0.01) { fail("%s sample rate expected 48000 got %.2f", label, f.mSampleRate); ok = false; } else pass("%s sample rate is 48000", label);
    if (f.mChannelsPerFrame != kExpectedChannels) { fail("%s channels expected 2 got %u", label, f.mChannelsPerFrame); ok = false; } else pass("%s has 2 channels", label);
    UInt32 neededFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    if (f.mFormatID != kAudioFormatLinearPCM || (f.mFormatFlags & neededFlags) != neededFlags || f.mBitsPerChannel != 32) {
        fail("%s expected Float32 packed LPCM formatID=%s flags=0x%x bits=%u", label, fourcc(f.mFormatID), f.mFormatFlags, f.mBitsPerChannel);
        ok = false;
    } else pass("%s is Float32 packed LPCM", label);
    CHECK(f.mBytesPerFrame == kExpectedChannels * sizeof(Float32) && f.mFramesPerPacket == 1 && f.mBytesPerPacket == f.mBytesPerFrame,
          "%s byte/packet layout is sane", label);
    return ok;
}

static bool check_stream(Driver& d, AudioObjectID streamID, UInt32 expectedDirection, AudioObjectID expectedOwner) {
    bool ok = true;
    ok &= expect_unknown(d, streamID);
    PropResult owner = get_prop(d, streamID, kAudioObjectPropertyOwner);
    CHECK(read_oid(owner) == expectedOwner, "Stream %u owner is device %u", streamID, expectedOwner);
    PropResult direction = get_prop(d, streamID, kAudioStreamPropertyDirection);
    CHECK(read_u32(direction) == expectedDirection, "Stream %u direction is %u", streamID, expectedDirection);
    PropResult vf = get_prop(d, streamID, kAudioStreamPropertyVirtualFormat);
    if (vf.status == noErr && vf.size == sizeof(AudioStreamBasicDescription)) ok &= check_format(*(AudioStreamBasicDescription*)vf.bytes.data(), "Virtual format"); else ok = false;
    PropResult pf = get_prop(d, streamID, kAudioStreamPropertyPhysicalFormat);
    if (pf.status == noErr && pf.size == sizeof(AudioStreamBasicDescription)) ok &= check_format(*(AudioStreamBasicDescription*)pf.bytes.data(), "Physical format"); else ok = false;
    PropResult avf = get_prop(d, streamID, kAudioStreamPropertyAvailableVirtualFormats);
    if (avf.status == noErr && avf.size == sizeof(AudioStreamRangedDescription)) {
        AudioStreamRangedDescription* rd = (AudioStreamRangedDescription*)avf.bytes.data();
        ok &= check_format(rd->mFormat, "Available virtual format");
        CHECK(rd->mSampleRateRange.mMinimum == kExpectedSampleRate && rd->mSampleRateRange.mMaximum == kExpectedSampleRate, "Available virtual format range is fixed at 48000");
    } else ok = false;
    PropResult start = get_prop(d, streamID, kAudioStreamPropertyStartingChannel);
    CHECK(read_u32(start) == 1, "Stream %u starts at channel 1", streamID);
    PropResult active = get_prop(d, streamID, kAudioStreamPropertyIsActive);
    CHECK(read_u32(active) == 1, "Stream %u is active", streamID);
    PropResult owned = get_prop(d, streamID, kAudioObjectPropertyOwnedObjects);
    CHECK(owned.size == 0, "Stream %u owns no objects", streamID);
    return ok;
}

// `kAudioDevicePropertyStreamConfiguration` ('slay') is part of the *client*
// facing HAL API in <CoreAudio/AudioHardware.h>, NOT the driver-facing
// AudioServerPlugIn API -- the constant does not appear anywhere in
// <CoreAudio/AudioServerPlugIn.h>. An AudioServerPlugIn must therefore NOT
// implement it: the HAL synthesises the AudioBufferList for clients itself by
// enumerating the device's owned AudioStream objects and reading each stream's
// direction, starting channel and virtual format. Apple's own minimal sample
// (NullAudio.c), which documents its property switch as "all the required
// properties plus a few extras", omits it, as does BlackHole.
//
// So the correct assertion is the inverse of the obvious one: the driver must
// answer *false*. Claiming the property here would be dead code in a bundle
// that gets loaded into coreaudiod. The layout the HAL actually derives 'slay'
// from is verified against the stream objects in `check_stream`.
static bool check_no_client_side_stream_config(Driver& d, AudioObjectID deviceID, UInt32 scope, const char* label) {
    AudioObjectPropertyAddress addr = { kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain };
    bool has = d.iface->HasProperty(d.ref, deviceID, 0, &addr);
    CHECK(!has, "%s does not claim client-side stream configuration", label);
    return !has;
}

static bool check_device(Driver& d, AudioObjectID deviceID, const char* name, const char* uid, bool hidden, bool canDefault,
                         UInt32 inputCount, AudioObjectID inputStream, UInt32 outputCount, AudioObjectID outputStream) {
    bool ok = true;
    ok &= expect_unknown(d, deviceID);
    PropResult n = get_prop(d, deviceID, kAudioObjectPropertyName);
    if (n.status == noErr && n.size == sizeof(CFStringRef)) {
        CFStringRef s = *(CFStringRef*)n.bytes.data();
        CHECK(same_cfstring(s, name), "Device %u name is %s", deviceID, name);
        if (s) CFRelease(s);
    }
    PropResult u = get_prop(d, deviceID, kAudioDevicePropertyDeviceUID);
    if (u.status == noErr && u.size == sizeof(CFStringRef)) {
        CFStringRef s = *(CFStringRef*)u.bytes.data();
        CHECK(same_cfstring(s, uid), "Device %u UID is %s", deviceID, uid);
        if (s) CFRelease(s);
    }
    PropResult model = get_prop(d, deviceID, kAudioDevicePropertyModelUID);
    if (model.status == noErr && model.size == sizeof(CFStringRef)) { CFStringRef s = *(CFStringRef*)model.bytes.data(); CHECK(s != nullptr, "Device %u model UID is non-null", deviceID); if (s) CFRelease(s); }
    PropResult man = get_prop(d, deviceID, kAudioObjectPropertyManufacturer);
    if (man.status == noErr && man.size == sizeof(CFStringRef)) { CFStringRef s = *(CFStringRef*)man.bytes.data(); CHECK(same_cfstring(s, "OpenConnect"), "Device %u manufacturer is OpenConnect", deviceID); if (s) CFRelease(s); }
    PropResult transport = get_prop(d, deviceID, kAudioDevicePropertyTransportType);
    CHECK(read_u32(transport) == kAudioDeviceTransportTypeVirtual, "Device %u transport is virtual", deviceID);
    PropResult rate = get_prop(d, deviceID, kAudioDevicePropertyNominalSampleRate);
    CHECK(std::fabs(read_f64(rate) - kExpectedSampleRate) < 0.01, "Device %u nominal sample rate is 48000", deviceID);
    PropResult ranges = get_prop(d, deviceID, kAudioDevicePropertyAvailableNominalSampleRates);
    if (ranges.status == noErr && ranges.size == sizeof(AudioValueRange)) {
        AudioValueRange* r = (AudioValueRange*)ranges.bytes.data();
        CHECK(r->mMinimum == kExpectedSampleRate && r->mMaximum == kExpectedSampleRate, "Device %u available sample-rate range is 48000", deviceID);
    }
    PropResult inStreams = get_prop(d, deviceID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
    CHECK(inStreams.size == inputCount * sizeof(AudioObjectID), "Device %u input stream list has %u stream(s)", deviceID, inputCount);
    if (inputCount) CHECK(read_oid(inStreams) == inputStream, "Device %u input stream object is %u", deviceID, inputStream);
    PropResult outStreams = get_prop(d, deviceID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
    CHECK(outStreams.size == outputCount * sizeof(AudioObjectID), "Device %u output stream list has %u stream(s)", deviceID, outputCount);
    if (outputCount) CHECK(read_oid(outStreams) == outputStream, "Device %u output stream object is %u", deviceID, outputStream);
    PropResult owned = get_prop(d, deviceID, kAudioObjectPropertyOwnedObjects);
    CHECK(owned.size == sizeof(AudioObjectID), "Device %u global owned objects has one stream", deviceID);
    CHECK(read_oid(owned) == (inputCount ? inputStream : outputStream), "Device %u owned stream ID is correct", deviceID);
    ok &= check_no_client_side_stream_config(d, deviceID, kAudioObjectPropertyScopeInput, "Device input scope");
    ok &= check_no_client_side_stream_config(d, deviceID, kAudioObjectPropertyScopeOutput, "Device output scope");
    PropResult hid = get_prop(d, deviceID, kAudioDevicePropertyIsHidden);
    CHECK(read_u32(hid) == (hidden ? 1u : 0u), "Device %u hidden flag is %u", deviceID, hidden ? 1 : 0);
    PropResult def = get_prop(d, deviceID, kAudioDevicePropertyDeviceCanBeDefaultDevice);
    CHECK(read_u32(def) == (canDefault ? 1u : 0u), "Device %u can-default flag is %u", deviceID, canDefault ? 1 : 0);
    PropResult lat = get_prop(d, deviceID, kAudioDevicePropertyLatency);
    CHECK(lat.status == noErr && lat.size == sizeof(UInt32), "Device %u latency is UInt32", deviceID);
    PropResult safety = get_prop(d, deviceID, kAudioDevicePropertySafetyOffset);
    CHECK(safety.status == noErr && safety.size == sizeof(UInt32), "Device %u safety offset is UInt32", deviceID);
    PropResult period = get_prop(d, deviceID, kAudioDevicePropertyZeroTimeStampPeriod);
    CHECK(read_u32(period) > 0, "Device %u zero timestamp period is positive", deviceID);
    return ok;
}

static void fill_time(AudioTimeStamp* ts, Float64 sample) {
    std::memset(ts, 0, sizeof(*ts));
    ts->mSampleTime = sample;
    ts->mHostTime = mach_absolute_time();
    ts->mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
}

static bool check_io(Driver& d) {
    bool ok = true;
    OSStatus st = d.iface->StartIO(d.ref, kObjectID_Device_Sink, kClientID);
    CHECK(st == noErr, "StartIO sink status=%d", (int)st);
    st = d.iface->StartIO(d.ref, kObjectID_Device_Mic, kClientID);
    CHECK(st == noErr, "StartIO mic status=%d", (int)st);

    Float64 s1 = 0, s2 = 0; UInt64 h1 = 0, h2 = 0, seed1 = 0, seed2 = 0;
    st = d.iface->GetZeroTimeStamp(d.ref, kObjectID_Device_Mic, kClientID, &s1, &h1, &seed1);
    CHECK(st == noErr, "GetZeroTimeStamp mic first status=%d", (int)st);
    // One zero-timestamp period is 16384 frames at 48 kHz (~341 ms).
    usleep(360000);
    st = d.iface->GetZeroTimeStamp(d.ref, kObjectID_Device_Mic, kClientID, &s2, &h2, &seed2);
    CHECK(st == noErr, "GetZeroTimeStamp mic second status=%d", (int)st);
    CHECK(s2 > s1 && h2 > h1 && seed1 == seed2, "GetZeroTimeStamp advances sample/host and keeps stable seed");

    Boolean will = false, inPlace = false;
    st = d.iface->WillDoIOOperation(d.ref, kObjectID_Device_Sink, kClientID, kAudioServerPlugInIOOperationWriteMix, &will, &inPlace);
    CHECK(st == noErr && will, "WillDoIOOperation sink WriteMix yes");
    st = d.iface->WillDoIOOperation(d.ref, kObjectID_Device_Mic, kClientID, kAudioServerPlugInIOOperationReadInput, &will, &inPlace);
    CHECK(st == noErr && will, "WillDoIOOperation mic ReadInput yes");
    st = d.iface->WillDoIOOperation(d.ref, kObjectID_Device_Mic, kClientID, kAudioServerPlugInIOOperationWriteMix, &will, &inPlace);
    CHECK(st == noErr && !will, "WillDoIOOperation mic WriteMix no");

    constexpr UInt32 frames = 128;
    std::vector<Float32> write(frames * kExpectedChannels), read(frames * kExpectedChannels, -99.0f);
    for (UInt32 f = 0; f < frames; ++f) {
        write[f * 2 + 0] = (Float32)f / 1000.0f;
        write[f * 2 + 1] = (Float32)(-((int)f)) / 1000.0f;
    }
    AudioServerPlugInIOCycleInfo cycle{};
    cycle.mIOCycleCounter = 1;
    cycle.mNominalIOBufferFrameSize = frames;
    fill_time(&cycle.mCurrentTime, 4096.0);
    fill_time(&cycle.mInputTime, 4096.0);
    fill_time(&cycle.mOutputTime, 4096.0);
    cycle.mMainHostTicksPerFrame = 1.0;
    cycle.mDeviceHostTicksPerFrame = 1.0;
    st = d.iface->BeginIOOperation(d.ref, kObjectID_Device_Sink, kClientID, kAudioServerPlugInIOOperationWriteMix, frames, &cycle);
    CHECK(st == noErr, "BeginIOOperation sink WriteMix");
    st = d.iface->DoIOOperation(d.ref, kObjectID_Device_Sink, kObjectID_Stream_Sink, kClientID, kAudioServerPlugInIOOperationWriteMix, frames, &cycle, write.data(), nullptr);
    CHECK(st == noErr, "DoIOOperation sink WriteMix");
    st = d.iface->EndIOOperation(d.ref, kObjectID_Device_Sink, kClientID, kAudioServerPlugInIOOperationWriteMix, frames, &cycle);
    CHECK(st == noErr, "EndIOOperation sink WriteMix");
    st = d.iface->DoIOOperation(d.ref, kObjectID_Device_Mic, kObjectID_Stream_Mic, kClientID, kAudioServerPlugInIOOperationReadInput, frames, &cycle, read.data(), nullptr);
    CHECK(st == noErr, "DoIOOperation mic ReadInput");
    bool same = true;
    for (size_t i = 0; i < write.size(); ++i) if (std::fabs(write[i] - read[i]) > 0.000001f) { same = false; break; }
    CHECK(same, "WriteMix data round-trips through mic ReadInput");

    usleep(250000);
    std::fill(read.begin(), read.end(), 123.0f);
    st = d.iface->DoIOOperation(d.ref, kObjectID_Device_Mic, kObjectID_Stream_Mic, kClientID, kAudioServerPlugInIOOperationReadInput, frames, &cycle, read.data(), nullptr);
    CHECK(st == noErr, "DoIOOperation mic stale ReadInput");
    bool silent = true;
    for (Float32 v : read) if (v != 0.0f) { silent = false; break; }
    CHECK(silent, "Stale writer guard returns silence after >200ms");

    st = d.iface->StopIO(d.ref, kObjectID_Device_Mic, kClientID);
    CHECK(st == noErr, "StopIO mic status=%d", (int)st);
    st = d.iface->StopIO(d.ref, kObjectID_Device_Sink, kClientID);
    CHECK(st == noErr, "StopIO sink status=%d", (int)st);
    return ok;
}

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s /path/to/OpenConnect.driver\n", argv[0]);
        return 2;
    }
    std::string binary = std::string(argv[1]) + "/Contents/MacOS/OpenConnect";
    void* handle = dlopen(binary.c_str(), RTLD_NOW | RTLD_LOCAL);
    REQUIRE_MAIN(handle != nullptr, "dlopen built driver binary %s", binary.c_str());
    using Factory = void* (*)(CFAllocatorRef, CFUUIDRef);
    Factory create = (Factory)dlsym(handle, "OpenConnect_Create");
    REQUIRE_MAIN(create != nullptr, "dlsym OpenConnect_Create");

    CFUUIDRef wrongType = CFUUIDCreate(NULL);
    void* wrong = create(kCFAllocatorDefault, wrongType);
    CHECK(wrong == nullptr, "Factory returns NULL for wrong type UUID");
    CFRelease(wrongType);

    void* instance = create(kCFAllocatorDefault, kAudioServerPlugInTypeUUID);
    REQUIRE_MAIN(instance != nullptr, "Factory returns non-NULL for HAL plug-in type UUID");
    Driver d;
    d.ref = (AudioServerPlugInDriverRef)instance;
    d.iface = *d.ref;
    REQUIRE_MAIN(d.iface != nullptr, "Driver interface pointer is non-NULL");

    LPVOID out = nullptr;
    HRESULT hr = d.iface->QueryInterface(d.ref, CFUUIDGetUUIDBytes(IUnknownUUID), &out);
    CHECK(hr == S_OK && out == d.ref, "QueryInterface IUnknown succeeds");
    out = nullptr;
    hr = d.iface->QueryInterface(d.ref, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &out);
    CHECK(hr == S_OK && out == d.ref, "QueryInterface AudioServerPlugInDriver succeeds");
    CFUUIDRef randomUUID = CFUUIDCreate(NULL);
    out = (void*)0x1;
    hr = d.iface->QueryInterface(d.ref, CFUUIDGetUUIDBytes(randomUUID), &out);
    CHECK(hr == E_NOINTERFACE, "QueryInterface random UUID fails with E_NOINTERFACE");
    CFRelease(randomUUID);
    ULONG rc1 = d.iface->AddRef(d.ref);
    ULONG rc2 = d.iface->Release(d.ref);
    CHECK(rc1 == rc2 + 1, "AddRef/Release update reference count (%lu -> %lu)", (unsigned long)rc1, (unsigned long)rc2);

    OSStatus st = d.iface->Initialize(d.ref, &gHost);
    REQUIRE_MAIN(st == noErr, "Initialize returns noErr");

    expect_unknown(d, kObjectID_PlugIn);
    PropResult manufacturer = get_prop(d, kObjectID_PlugIn, kAudioObjectPropertyManufacturer);
    if (manufacturer.status == noErr && manufacturer.size == sizeof(CFStringRef)) {
        CFStringRef s = *(CFStringRef*)manufacturer.bytes.data();
        CHECK(same_cfstring(s, "OpenConnect"), "Plug-in manufacturer is OpenConnect");
        if (s) CFRelease(s);
    }
    PropResult devices = get_prop(d, kObjectID_PlugIn, kAudioPlugInPropertyDeviceList);
    REQUIRE_MAIN(devices.status == noErr && devices.size == 2 * sizeof(AudioObjectID), "Plug-in device list contains exactly two devices");
    AudioObjectID* ids = (AudioObjectID*)devices.bytes.data();
    CHECK(ids[0] == kObjectID_Device_Mic && ids[1] == kObjectID_Device_Sink, "Plug-in device list IDs are mic=2 sink=4");

    CFStringRef micUID = CFSTR("OpenConnectMic_UID");
    CFStringRef sinkUID = CFSTR("OpenConnectSink_UID");
    CFStringRef unknownUID = CFSTR("DefinitelyNotOpenConnect_UID");
    PropResult micTranslate = get_prop(d, kObjectID_PlugIn, kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, sizeof(CFStringRef), &micUID, "mic UID");
    CHECK(read_oid(micTranslate) == kObjectID_Device_Mic, "Translate mic UID returns object 2");
    PropResult sinkTranslate = get_prop(d, kObjectID_PlugIn, kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, sizeof(CFStringRef), &sinkUID, "sink UID");
    CHECK(read_oid(sinkTranslate) == kObjectID_Device_Sink, "Translate sink UID returns object 4");
    PropResult unknownTranslate = get_prop(d, kObjectID_PlugIn, kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, sizeof(CFStringRef), &unknownUID, "unknown UID");
    CHECK(read_oid(unknownTranslate) == kAudioObjectUnknown, "Translate unknown UID returns kAudioObjectUnknown");

    check_device(d, kObjectID_Device_Mic, "OpenConnect Mic", "OpenConnectMic_UID", false, true, 1, kObjectID_Stream_Mic, 0, 0);
    check_device(d, kObjectID_Device_Sink, "OpenConnect Sink", "OpenConnectSink_UID", true, false, 0, 0, 1, kObjectID_Stream_Sink);
    check_stream(d, kObjectID_Stream_Mic, 1, kObjectID_Device_Mic);
    check_stream(d, kObjectID_Stream_Sink, 0, kObjectID_Device_Sink);

    bool graphOK = true;
    for (AudioObjectID id : { kObjectID_Device_Mic, kObjectID_Device_Sink, kObjectID_Stream_Mic, kObjectID_Stream_Sink }) {
        AudioObjectPropertyAddress classAddr = { kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        bool has = d.iface->HasProperty(d.ref, id, 0, &classAddr);
        CHECK(has, "Object graph ID %u answers basic class property", id);
        graphOK &= has;
    }
    CHECK(graphOK, "Object ownership graph has no dangling IDs");

    check_io(d);

    ULONG releaseAfterQI1 = d.iface->Release(d.ref);
    ULONG releaseAfterQI2 = d.iface->Release(d.ref);
    ULONG finalRelease = d.iface->Release(d.ref);
    CHECK(finalRelease == 0, "Final Release reaches zero after QueryInterface/AddRef balances (%lu, %lu, %lu)", (unsigned long)releaseAfterQI1, (unsigned long)releaseAfterQI2, (unsigned long)finalRelease);
    CHECK(gPropertiesChangedCalls == 0, "Fake host remained valid; PropertiesChanged calls recorded=%u", gPropertiesChangedCalls);
    dlclose(handle);
    std::printf("SUMMARY %d passed, %d failed\n", gPasses, gFailures);
    return gFailures == 0 ? 0 : 1;
}
