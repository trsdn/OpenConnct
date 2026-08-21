//  OpenConnectDriver.c
//
//  CoreAudio AudioServerPlugIn for OpenConnect.
//
//  This code is loaded into `coreaudiod`. A fault here takes down audio for the entire
//  machine, so the driver is deliberately as dumb as possible: it is a pure loopback with
//  a shared ring buffer and no DSP, no dependencies and no IPC. All signal processing
//  lives in OpenConnect.app.
//
//  Two devices are published, backed by the same ring buffer:
//
//    "OpenConnect Mic"   visible, input-only   -> what Teams/Zoom/OBS select
//    "OpenConnect Sink"  hidden,  output-only  -> what OpenConnect.app renders into
//
//  Hiding the sink stops users selecting it as their speakers and structurally prevents
//  feedback loops.
//
//  Realtime rules for everything reachable from DoIOOperation/GetZeroTimeStamp:
//  no allocation, no locks, no CF calls, no logging, no unbounded work.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <string.h>
#include <pthread.h>

#pragma mark - Configuration

#define kDriver_Version             "1.0.0"

#define kPlugIn_BundleID            "audio.openconnect.driver"
#define kManufacturer_Name          CFSTR("OpenConnect")

#define kMicDevice_Name             CFSTR("OpenConnect Mic")
#define kMicDevice_UID              CFSTR("OpenConnectMic_UID")
#define kMicDevice_ModelUID         CFSTR("OpenConnectMic_ModelUID")

#define kSinkDevice_Name            CFSTR("OpenConnect Sink")
#define kSinkDevice_UID             CFSTR("OpenConnectSink_UID")
#define kSinkDevice_ModelUID        CFSTR("OpenConnectSink_ModelUID")

// v1 is fixed at 48 kHz. The app resamples every hardware mic to this rate anyway, and a
// single supported rate removes the entire device-configuration-change state machine,
// which is a common source of glitches and races in virtual drivers.
#define kSampleRate                 48000.0
#define kChannelCount               2u

// Power of two: the ring is indexed by sample time modulo its length.
#define kRingFrames                 16384u
#define kRingSamples                (kRingFrames * kChannelCount)

// How long the mic device keeps emitting the ring contents after the app stops writing.
// Without this, a stopped app would leave the last ring-full of audio looping forever.
#define kWriterStaleNanos           200000000ull   // 200 ms

// Custom property: lets the app confirm it is talking to a matching driver build.
#define kOpenConnectCustomProperty_Version  'ocvs'

#pragma mark - Object IDs

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Device_Mic    = 2,
    kObjectID_Stream_Mic    = 3,
    kObjectID_Device_Sink   = 4,
    kObjectID_Stream_Sink   = 5
};

#pragma mark - State

// Guards non-realtime state only. Never taken on the IO path.
static pthread_mutex_t              gStateMutex = PTHREAD_MUTEX_INITIALIZER;

static AudioServerPlugInHostRef     gPlugInHost = NULL;
static UInt32                       gPlugInRefCount = 0;

static UInt32                       gMicRunCount = 0;
static UInt32                       gSinkRunCount = 0;

static Float64                      gHostTicksPerFrame = 0.0;
static Float64                      gWriterStaleTicks = 0.0;

// GetZeroTimeStamp bookkeeping, one set per device. Touched only from the IO thread of
// the corresponding device.
static UInt64                       gMicAnchorHostTime = 0;
static UInt64                       gMicTimestampCount = 0;
static UInt64                       gSinkAnchorHostTime = 0;
static UInt64                       gSinkTimestampCount = 0;

// The shared loopback buffer. Indexed by absolute sample time modulo kRingFrames, which
// is what lets two independent device IO cycles agree on a position without any pointer
// handshake: both device clocks are derived from mach_absolute_time() with the identical
// formula, so they advance at the same rate.
static Float32                      gRing[kRingSamples];
static _Atomic(uint64_t)            gLastWriteHostTime = 0;

#pragma mark - Helpers

static void OpenConnect_InitTimebase(void)
{
    if (gHostTicksPerFrame != 0.0) { return; }

    struct mach_timebase_info info;
    mach_timebase_info(&info);
    Float64 hostTicksPerSecond = ((Float64)info.denom / (Float64)info.numer) * 1000000000.0;
    gHostTicksPerFrame = hostTicksPerSecond / kSampleRate;
    // Precomputed here so the IO cycle only has to do one comparison.
    gWriterStaleTicks = hostTicksPerSecond * ((Float64)kWriterStaleNanos / 1000000000.0);
}

static Boolean OpenConnect_IsDeviceID(AudioObjectID inObjectID)
{
    return (inObjectID == kObjectID_Device_Mic) || (inObjectID == kObjectID_Device_Sink);
}

static Boolean OpenConnect_IsStreamID(AudioObjectID inObjectID)
{
    return (inObjectID == kObjectID_Stream_Mic) || (inObjectID == kObjectID_Stream_Sink);
}

static Boolean OpenConnect_IsInputObject(AudioObjectID inObjectID)
{
    return (inObjectID == kObjectID_Device_Mic) || (inObjectID == kObjectID_Stream_Mic);
}

static AudioObjectID OpenConnect_StreamForDevice(AudioObjectID inDeviceID)
{
    return (inDeviceID == kObjectID_Device_Mic) ? kObjectID_Stream_Mic : kObjectID_Stream_Sink;
}

static void OpenConnect_FillStreamFormat(AudioStreamBasicDescription* outFormat)
{
    outFormat->mSampleRate       = kSampleRate;
    outFormat->mFormatID         = kAudioFormatLinearPCM;
    outFormat->mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    outFormat->mBytesPerPacket   = kChannelCount * sizeof(Float32);
    outFormat->mFramesPerPacket  = 1;
    outFormat->mBytesPerFrame    = kChannelCount * sizeof(Float32);
    outFormat->mChannelsPerFrame = kChannelCount;
    outFormat->mBitsPerChannel   = 32;
    outFormat->mReserved         = 0;
}

#pragma mark - Forward declarations

static HRESULT  OpenConnect_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    OpenConnect_AddRef(void* inDriver);
static ULONG    OpenConnect_Release(void* inDriver);
static OSStatus OpenConnect_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus OpenConnect_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus OpenConnect_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus OpenConnect_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus OpenConnect_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus OpenConnect_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus OpenConnect_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean  OpenConnect_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus OpenConnect_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus OpenConnect_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus OpenConnect_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus OpenConnect_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus OpenConnect_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus OpenConnect_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus OpenConnect_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus OpenConnect_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus OpenConnect_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus OpenConnect_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus OpenConnect_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

#pragma mark - Interface

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    OpenConnect_QueryInterface,
    OpenConnect_AddRef,
    OpenConnect_Release,
    OpenConnect_Initialize,
    OpenConnect_CreateDevice,
    OpenConnect_DestroyDevice,
    OpenConnect_AddDeviceClient,
    OpenConnect_RemoveDeviceClient,
    OpenConnect_PerformDeviceConfigurationChange,
    OpenConnect_AbortDeviceConfigurationChange,
    OpenConnect_HasProperty,
    OpenConnect_IsPropertySettable,
    OpenConnect_GetPropertyDataSize,
    OpenConnect_GetPropertyData,
    OpenConnect_SetPropertyData,
    OpenConnect_StartIO,
    OpenConnect_StopIO,
    OpenConnect_GetZeroTimeStamp,
    OpenConnect_WillDoIOOperation,
    OpenConnect_BeginIOOperation,
    OpenConnect_DoIOOperation,
    OpenConnect_EndIOOperation
};

static AudioServerPlugInDriverInterface*    gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef           gInstance = &gInterfacePtr;

void*   OpenConnect_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void*   OpenConnect_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    #pragma unused(inAllocator)
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) { return NULL; }
    return gInstance;
}

#pragma mark - IUnknown

static HRESULT OpenConnect_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if ((inDriver != gInstance) || (outInterface == NULL)) { return kAudioHardwareBadObjectError; }

    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) { return kAudioHardwareIllegalOperationError; }

    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        ++gPlugInRefCount;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gInstance;
        result = S_OK;
    }

    CFRelease(requested);
    return result;
}

static ULONG OpenConnect_AddRef(void* inDriver)
{
    if (inDriver != gInstance) { return 0; }

    pthread_mutex_lock(&gStateMutex);
    if (gPlugInRefCount < UINT32_MAX) { ++gPlugInRefCount; }
    ULONG result = gPlugInRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return result;
}

static ULONG OpenConnect_Release(void* inDriver)
{
    if (inDriver != gInstance) { return 0; }

    pthread_mutex_lock(&gStateMutex);
    if (gPlugInRefCount > 0) { --gPlugInRefCount; }
    ULONG result = gPlugInRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return result;
}

#pragma mark - Lifecycle

static OSStatus OpenConnect_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if (inDriver != gInstance) { return kAudioHardwareBadObjectError; }

    gPlugInHost = inHost;
    OpenConnect_InitTimebase();
    memset(gRing, 0, sizeof(gRing));
    atomic_store_explicit(&gLastWriteHostTime, 0, memory_order_relaxed);

    return noErr;
}

static OSStatus OpenConnect_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    #pragma unused(inDescription, inClientInfo, outDeviceObjectID)
    if (inDriver != gInstance) { return kAudioHardwareBadObjectError; }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus OpenConnect_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    #pragma unused(inDeviceObjectID)
    if (inDriver != gInstance) { return kAudioHardwareBadObjectError; }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus OpenConnect_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    #pragma unused(inClientInfo)
    if (inDriver != gInstance) { return kAudioHardwareBadObjectError; }
    if (!OpenConnect_IsDeviceID(inDeviceObjectID)) { return kAudioHardwareBadObjectError; }
    return noErr;
}

static OSStatus OpenConnect_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    #pragma unused(inClientInfo)
    if (inDriver != gInstance) { return kAudioHardwareBadObjectError; }
    if (!OpenConnect_IsDeviceID(inDeviceObjectID)) { return kAudioHardwareBadObjectError; }
    return noErr;
}

// The device exposes a single fixed format, so there is never a configuration change to
// perform. Both hooks exist only to satisfy the interface contract.
static OSStatus OpenConnect_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inChangeAction, inChangeInfo)
    if (inDriver != gInstance) { return kAudioHardwareBadObjectError; }
    if (!OpenConnect_IsDeviceID(inDeviceObjectID)) { return kAudioHardwareBadObjectError; }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus OpenConnect_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inChangeAction, inChangeInfo)
    if (inDriver != gInstance) { return kAudioHardwareBadObjectError; }
    if (!OpenConnect_IsDeviceID(inDeviceObjectID)) { return kAudioHardwareBadObjectError; }
    return noErr;
}

#pragma mark - Properties: PlugIn

static Boolean OpenConnect_HasPlugInProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
        case kOpenConnectCustomProperty_Version:
            return true;
        default:
            return false;
    }
}

static OSStatus OpenConnect_GetPlugInPropertyDataSize(const AudioObjectPropertyAddress* inAddress, UInt32* outDataSize)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
        case kOpenConnectCustomProperty_Version:
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = 2 * sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus OpenConnect_GetPlugInPropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;

        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioClassID*)outData) = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;

        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioObjectID*)outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;

        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) { return kAudioHardwareBadPropertySizeError; }
            *((CFStringRef*)outData) = CFStringCreateCopy(NULL, kManufacturer_Name);
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            AudioObjectID* ids = (AudioObjectID*)outData;
            UInt32 capacity = inDataSize / sizeof(AudioObjectID);
            UInt32 written = 0;
            if (capacity > 0) { ids[written++] = kObjectID_Device_Mic; }
            if (capacity > 1) { ids[written++] = kObjectID_Device_Sink; }
            *outDataSize = written * sizeof(AudioObjectID);
            return noErr;
        }

        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (inQualifierDataSize != sizeof(CFStringRef)) { return kAudioHardwareBadPropertySizeError; }
            if (inDataSize < sizeof(AudioObjectID)) { return kAudioHardwareBadPropertySizeError; }
            CFStringRef uid = *((const CFStringRef*)inQualifierData);
            AudioObjectID match = kAudioObjectUnknown;
            if (uid != NULL) {
                if (CFStringCompare(uid, kMicDevice_UID, 0) == kCFCompareEqualTo) {
                    match = kObjectID_Device_Mic;
                } else if (CFStringCompare(uid, kSinkDevice_UID, 0) == kCFCompareEqualTo) {
                    match = kObjectID_Device_Sink;
                }
            }
            *((AudioObjectID*)outData) = match;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        }

        case kAudioPlugInPropertyResourceBundle:
            if (inDataSize < sizeof(CFStringRef)) { return kAudioHardwareBadPropertySizeError; }
            *((CFStringRef*)outData) = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioObjectPropertyCustomPropertyInfoList: {
            if (inDataSize < sizeof(AudioServerPlugInCustomPropertyInfo)) { return kAudioHardwareBadPropertySizeError; }
            AudioServerPlugInCustomPropertyInfo* info = (AudioServerPlugInCustomPropertyInfo*)outData;
            info->mSelector = kOpenConnectCustomProperty_Version;
            info->mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFString;
            info->mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
            *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
            return noErr;
        }

        case kOpenConnectCustomProperty_Version:
            if (inDataSize < sizeof(CFStringRef)) { return kAudioHardwareBadPropertySizeError; }
            *((CFStringRef*)outData) = CFStringCreateWithCString(NULL, kDriver_Version, kCFStringEncodingUTF8);
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Properties: Device

static Boolean OpenConnect_HasDeviceProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            return true;
        default:
            return false;
    }
}

// A device only owns streams matching the requested scope. The mic device is input-only
// and the sink device is output-only, so a mismatched scope yields an empty list.
static UInt32 OpenConnect_StreamCountForScope(AudioObjectID inDeviceID, AudioObjectPropertyScope inScope)
{
    Boolean isInput = (inDeviceID == kObjectID_Device_Mic);
    if (inScope == kAudioObjectPropertyScopeGlobal) { return 1; }
    if (isInput && (inScope == kAudioObjectPropertyScopeInput)) { return 1; }
    if (!isInput && (inScope == kAudioObjectPropertyScopeOutput)) { return 1; }
    return 0;
}

static OSStatus OpenConnect_GetDevicePropertyDataSize(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, UInt32* outDataSize)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            *outDataSize = OpenConnect_StreamCountForScope(inObjectID, inAddress->mScope) * sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return noErr;
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = sizeof(AudioValueRange);
            return noErr;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (kChannelCount * sizeof(AudioChannelDescription));
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus OpenConnect_GetDevicePropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    Boolean isMic = (inObjectID == kObjectID_Device_Mic);

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;

        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioClassID*)outData) = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;

        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioObjectID*)outData) = kObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;

        case kAudioObjectPropertyName:
            if (inDataSize < sizeof(CFStringRef)) { return kAudioHardwareBadPropertySizeError; }
            *((CFStringRef*)outData) = CFStringCreateCopy(NULL, isMic ? kMicDevice_Name : kSinkDevice_Name);
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) { return kAudioHardwareBadPropertySizeError; }
            *((CFStringRef*)outData) = CFStringCreateCopy(NULL, kManufacturer_Name);
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioDevicePropertyDeviceUID:
            if (inDataSize < sizeof(CFStringRef)) { return kAudioHardwareBadPropertySizeError; }
            *((CFStringRef*)outData) = CFStringCreateCopy(NULL, isMic ? kMicDevice_UID : kSinkDevice_UID);
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioDevicePropertyModelUID:
            if (inDataSize < sizeof(CFStringRef)) { return kAudioHardwareBadPropertySizeError; }
            *((CFStringRef*)outData) = CFStringCreateCopy(NULL, isMic ? kMicDevice_ModelUID : kSinkDevice_ModelUID);
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            UInt32 count = OpenConnect_StreamCountForScope(inObjectID, inAddress->mScope);
            UInt32 capacity = inDataSize / sizeof(AudioObjectID);
            if (count > capacity) { count = capacity; }
            if (count > 0) { ((AudioObjectID*)outData)[0] = OpenConnect_StreamForDevice(inObjectID); }
            *outDataSize = count * sizeof(AudioObjectID);
            return noErr;
        }

        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return noErr;

        case kAudioDevicePropertyRelatedDevices:
            if (inDataSize < sizeof(AudioObjectID)) { return kAudioHardwareBadPropertySizeError; }
            ((AudioObjectID*)outData)[0] = inObjectID;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;

        case kAudioDevicePropertyTransportType:
            if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyClockDomain:
            if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyDeviceIsAlive:
            if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyDeviceIsRunning: {
            if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = (isMic ? gMicRunCount : gSinkRunCount) > 0 ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            *((UInt32*)outData) = running;
            *outDataSize = sizeof(UInt32);
            return noErr;
        }

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = isMic ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyIsHidden:
            if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = isMic ? 0 : 1;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyNominalSampleRate:
            if (inDataSize < sizeof(Float64)) { return kAudioHardwareBadPropertySizeError; }
            *((Float64*)outData) = kSampleRate;
            *outDataSize = sizeof(Float64);
            return noErr;

        case kAudioDevicePropertyAvailableNominalSampleRates: {
            if (inDataSize < sizeof(AudioValueRange)) {
                *outDataSize = 0;
                return noErr;
            }
            AudioValueRange* range = (AudioValueRange*)outData;
            range->mMinimum = kSampleRate;
            range->mMaximum = kSampleRate;
            *outDataSize = sizeof(AudioValueRange);
            return noErr;
        }

        case kAudioDevicePropertyPreferredChannelsForStereo:
            if (inDataSize < (2 * sizeof(UInt32))) { return kAudioHardwareBadPropertySizeError; }
            ((UInt32*)outData)[0] = 1;
            ((UInt32*)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 required = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + (kChannelCount * sizeof(AudioChannelDescription)));
            if (inDataSize < required) { return kAudioHardwareBadPropertySizeError; }
            AudioChannelLayout* layout = (AudioChannelLayout*)outData;
            memset(layout, 0, required);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = kChannelCount;
            layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outDataSize = required;
            return noErr;
        }

        case kAudioDevicePropertyZeroTimeStampPeriod:
            if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = kRingFrames;
            *outDataSize = sizeof(UInt32);
            return noErr;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Properties: Stream

static Boolean OpenConnect_HasStreamProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static OSStatus OpenConnect_GetStreamPropertyDataSize(const AudioObjectPropertyAddress* inAddress, UInt32* outDataSize)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return noErr;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus OpenConnect_GetStreamPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    Boolean isInput = OpenConnect_IsInputObject(inObjectID);

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;

        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioClassID*)outData) = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;

        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) { return kAudioHardwareBadPropertySizeError; }
            *((AudioObjectID*)outData) = isInput ? kObjectID_Device_Mic : kObjectID_Device_Sink;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return noErr;

        case kAudioStreamPropertyIsActive:
            if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioStreamPropertyDirection:
            if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = isInput ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioStreamPropertyTerminalType:
            if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioStreamPropertyStartingChannel:
            if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 1;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioStreamPropertyLatency:
            if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            *((UInt32*)outData) = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            if (inDataSize < sizeof(AudioStreamBasicDescription)) { return kAudioHardwareBadPropertySizeError; }
            OpenConnect_FillStreamFormat((AudioStreamBasicDescription*)outData);
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return noErr;

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            if (inDataSize < sizeof(AudioStreamRangedDescription)) {
                *outDataSize = 0;
                return noErr;
            }
            AudioStreamRangedDescription* desc = (AudioStreamRangedDescription*)outData;
            OpenConnect_FillStreamFormat(&desc->mFormat);
            desc->mSampleRateRange.mMinimum = kSampleRate;
            desc->mSampleRateRange.mMaximum = kSampleRate;
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return noErr;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Property dispatch

static Boolean OpenConnect_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    #pragma unused(inClientProcessID)
    if ((inDriver != gInstance) || (inAddress == NULL)) { return false; }

    if (inObjectID == kObjectID_PlugIn)         { return OpenConnect_HasPlugInProperty(inAddress); }
    if (OpenConnect_IsDeviceID(inObjectID))     { return OpenConnect_HasDeviceProperty(inAddress); }
    if (OpenConnect_IsStreamID(inObjectID))     { return OpenConnect_HasStreamProperty(inAddress); }
    return false;
}

static OSStatus OpenConnect_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    #pragma unused(inClientProcessID)
    if ((inDriver != gInstance) || (inAddress == NULL) || (outIsSettable == NULL)) { return kAudioHardwareIllegalOperationError; }

    if (!OpenConnect_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    // Nothing is settable: the device is intentionally a fixed-format loopback.
    *outIsSettable = false;
    return noErr;
}

static OSStatus OpenConnect_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)
    if ((inDriver != gInstance) || (inAddress == NULL) || (outDataSize == NULL)) { return kAudioHardwareIllegalOperationError; }

    if (inObjectID == kObjectID_PlugIn)     { return OpenConnect_GetPlugInPropertyDataSize(inAddress, outDataSize); }
    if (OpenConnect_IsDeviceID(inObjectID)) { return OpenConnect_GetDevicePropertyDataSize(inObjectID, inAddress, outDataSize); }
    if (OpenConnect_IsStreamID(inObjectID)) { return OpenConnect_GetStreamPropertyDataSize(inAddress, outDataSize); }
    return kAudioHardwareBadObjectError;
}

static OSStatus OpenConnect_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    #pragma unused(inClientProcessID)
    if ((inDriver != gInstance) || (inAddress == NULL) || (outDataSize == NULL) || (outData == NULL)) { return kAudioHardwareIllegalOperationError; }

    if (inObjectID == kObjectID_PlugIn) {
        return OpenConnect_GetPlugInPropertyData(inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
    }
    if (OpenConnect_IsDeviceID(inObjectID)) {
        return OpenConnect_GetDevicePropertyData(inObjectID, inAddress, inDataSize, outDataSize, outData);
    }
    if (OpenConnect_IsStreamID(inObjectID)) {
        return OpenConnect_GetStreamPropertyData(inObjectID, inAddress, inDataSize, outDataSize, outData);
    }
    return kAudioHardwareBadObjectError;
}

static OSStatus OpenConnect_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    #pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData, inDataSize, inData)
    if ((inDriver != gInstance) || (inAddress == NULL)) { return kAudioHardwareIllegalOperationError; }

    if (!OpenConnect_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareUnsupportedOperationError;
}

#pragma mark - IO

static OSStatus OpenConnect_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    if (inDriver != gInstance) { return kAudioHardwareBadObjectError; }
    if (!OpenConnect_IsDeviceID(inDeviceObjectID)) { return kAudioHardwareBadObjectError; }

    pthread_mutex_lock(&gStateMutex);
    if (inDeviceObjectID == kObjectID_Device_Mic) {
        if (gMicRunCount == 0) {
            gMicAnchorHostTime = mach_absolute_time();
            gMicTimestampCount = 0;
        }
        ++gMicRunCount;
    } else {
        if (gSinkRunCount == 0) {
            gSinkAnchorHostTime = mach_absolute_time();
            gSinkTimestampCount = 0;
        }
        ++gSinkRunCount;
    }
    pthread_mutex_unlock(&gStateMutex);

    return noErr;
}

static OSStatus OpenConnect_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    if (inDriver != gInstance) { return kAudioHardwareBadObjectError; }
    if (!OpenConnect_IsDeviceID(inDeviceObjectID)) { return kAudioHardwareBadObjectError; }

    pthread_mutex_lock(&gStateMutex);
    if (inDeviceObjectID == kObjectID_Device_Mic) {
        if (gMicRunCount > 0) { --gMicRunCount; }
    } else {
        if (gSinkRunCount > 0) { --gSinkRunCount; }
    }
    pthread_mutex_unlock(&gStateMutex);

    return noErr;
}

// Both devices derive their timeline from mach_absolute_time() using the identical
// formula, so they advance at exactly the same rate. That is what allows the ring buffer
// to be indexed by absolute sample time from two independent IO cycles with no handshake.
//
// outSeed stays constant: the timeline never resets, and bumping it spuriously forces
// clients to resynchronise, which is audible.
static OSStatus OpenConnect_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    #pragma unused(inClientID)
    if (inDriver != gInstance) { return kAudioHardwareBadObjectError; }
    if (!OpenConnect_IsDeviceID(inDeviceObjectID)) { return kAudioHardwareBadObjectError; }

    Boolean isMic = (inDeviceObjectID == kObjectID_Device_Mic);
    UInt64* anchor = isMic ? &gMicAnchorHostTime : &gSinkAnchorHostTime;
    UInt64* count = isMic ? &gMicTimestampCount : &gSinkTimestampCount;

    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kRingFrames;
    UInt64 now = mach_absolute_time();

    // Advance one whole period at a time so the reported pair stays exactly on the
    // device's nominal grid; the HAL interpolates between them.
    UInt64 nextPeriodHostTime = *anchor + (UInt64)(((Float64)(*count) + 1.0) * ticksPerPeriod);
    if (now >= nextPeriodHostTime) {
        ++(*count);
    }

    *outSampleTime = (Float64)(*count) * (Float64)kRingFrames;
    *outHostTime = *anchor + (UInt64)((Float64)(*count) * ticksPerPeriod);
    *outSeed = 1;

    return noErr;
}

static OSStatus OpenConnect_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    #pragma unused(inClientID)
    if (inDriver != gInstance) { return kAudioHardwareBadObjectError; }
    if (!OpenConnect_IsDeviceID(inDeviceObjectID)) { return kAudioHardwareBadObjectError; }

    Boolean willDo = false;
    Boolean willDoInPlace = true;

    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
            willDo = (inDeviceObjectID == kObjectID_Device_Mic);
            break;
        case kAudioServerPlugInIOOperationWriteMix:
            willDo = (inDeviceObjectID == kObjectID_Device_Sink);
            break;
        default:
            break;
    }

    if (outWillDo != NULL)          { *outWillDo = willDo; }
    if (outWillDoInPlace != NULL)   { *outWillDoInPlace = willDoInPlace; }
    return noErr;
}

static OSStatus OpenConnect_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    if (inDriver != gInstance) { return kAudioHardwareBadObjectError; }
    if (!OpenConnect_IsDeviceID(inDeviceObjectID)) { return kAudioHardwareBadObjectError; }
    return noErr;
}

// Realtime. No allocation, no locks, no CF, no logging.
static OSStatus OpenConnect_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    #pragma unused(inStreamObjectID, inClientID, ioSecondaryBuffer)
    if (inDriver != gInstance) { return kAudioHardwareBadObjectError; }
    if ((ioMainBuffer == NULL) || (inIOCycleInfo == NULL)) { return noErr; }
    if (inIOBufferFrameSize == 0) { return noErr; }

    Float32* buffer = (Float32*)ioMainBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        if (inDeviceObjectID != kObjectID_Device_Sink) { return noErr; }
        UInt64 startFrame = (UInt64)inIOCycleInfo->mOutputTime.mSampleTime;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; ++frame) {
            UInt32 ringFrame = (UInt32)((startFrame + frame) & (kRingFrames - 1));
            Float32* dst = &gRing[ringFrame * kChannelCount];
            const Float32* src = &buffer[frame * kChannelCount];
            for (UInt32 ch = 0; ch < kChannelCount; ++ch) { dst[ch] = src[ch]; }
        }
        atomic_store_explicit(&gLastWriteHostTime, mach_absolute_time(), memory_order_release);
        return noErr;
    }

    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        if (inDeviceObjectID != kObjectID_Device_Mic) { return noErr; }

        // If the app stopped rendering, emit silence rather than looping stale ring
        // contents forever.
        UInt64 lastWrite = atomic_load_explicit(&gLastWriteHostTime, memory_order_acquire);
        Boolean writerLive = false;
        if (lastWrite != 0) {
            UInt64 now = mach_absolute_time();
            UInt64 elapsedTicks = (now > lastWrite) ? (now - lastWrite) : 0;
            writerLive = ((Float64)elapsedTicks < gWriterStaleTicks);
        }

        if (!writerLive) {
            memset(buffer, 0, (size_t)inIOBufferFrameSize * kChannelCount * sizeof(Float32));
            return noErr;
        }

        UInt64 startFrame = (UInt64)inIOCycleInfo->mInputTime.mSampleTime;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; ++frame) {
            UInt32 ringFrame = (UInt32)((startFrame + frame) & (kRingFrames - 1));
            const Float32* src = &gRing[ringFrame * kChannelCount];
            Float32* dst = &buffer[frame * kChannelCount];
            for (UInt32 ch = 0; ch < kChannelCount; ++ch) { dst[ch] = src[ch]; }
        }
        return noErr;
    }

    return noErr;
}

static OSStatus OpenConnect_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    if (inDriver != gInstance) { return kAudioHardwareBadObjectError; }
    if (!OpenConnect_IsDeviceID(inDeviceObjectID)) { return kAudioHardwareBadObjectError; }
    return noErr;
}
