#import "av_audio.h"

@implementation AVAudio


+ (NSArray<NSString *> *)microphoneNames {
  AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInMicrophone,
    AVCaptureDeviceTypeExternalUnknown]
                                                                                                             mediaType:AVMediaTypeAudio
                                                                                                              position:AVCaptureDevicePositionUnspecified];

  NSMutableArray *result = [[NSMutableArray alloc] init];

  for(AVCaptureDevice *device in discoverySession.devices) {
    [result addObject:[device localizedName]];
  }

  return result;
}

- (void)dealloc {
  // make sure we don't process any further samples
  self.audioConnection = nil;
  [self.audioCaptureSession release];
  [self.samplesArrivedSignal release];
  TPCircularBufferCleanup(&audioSampleBuffer);
  [super dealloc];
}

- (int)setupMicrophoneWithName:(NSString *)name sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels {
  AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInMicrophone,
    AVCaptureDeviceTypeExternalUnknown]
                                                                                                             mediaType:AVMediaTypeAudio
                                                                                                              position:AVCaptureDevicePositionUnspecified];

  AVCaptureDevice *inputDevice = nil;

  for(AVCaptureDevice *device in discoverySession.devices) {
    if([[device localizedName] isEqualToString:name]) {
      inputDevice = device;
    }
  }

  if(!inputDevice) {
    return -1;
  }

  self.audioCaptureSession = [[AVCaptureSession alloc] init];

  NSError *error;
  AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:inputDevice error:&error];
  if(audioInput == nil) {
    return -1;
  }

  if([self.audioCaptureSession canAddInput:audioInput]) {
    [self.audioCaptureSession addInput:audioInput];
  }
  else {
    [audioInput dealloc];
    return -1;
  }

  AVCaptureAudioDataOutput *audioOutput = [[AVCaptureAudioDataOutput alloc] init];


  [audioOutput setAudioSettings:@{
    (NSString *)AVFormatIDKey: [NSNumber numberWithUnsignedInt:kAudioFormatLinearPCM],
    (NSString *)AVSampleRateKey: [NSNumber numberWithUnsignedInt:sampleRate],
    (NSString *)AVNumberOfChannelsKey: [NSNumber numberWithUnsignedInt:channels],
    (NSString *)AVLinearPCMBitDepthKey: [NSNumber numberWithUnsignedInt:16],
    (NSString *)AVLinearPCMIsFloatKey: @NO,
    (NSString *)AVLinearPCMIsNonInterleaved: @NO
  }];

  dispatch_queue_attr_t qos       = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, DISPATCH_QUEUE_PRIORITY_HIGH);
  dispatch_queue_t recordingQueue = dispatch_queue_create("audioSamplingQueue", qos);

  [audioOutput setSampleBufferDelegate:self queue:recordingQueue];

  if([self.audioCaptureSession canAddOutput:audioOutput]) {
    [self.audioCaptureSession addOutput:audioOutput];
  }
  else {
    [audioInput release];
    [audioOutput release];
    return -1;
  }

  self.audioConnection = [audioOutput connectionWithMediaType:AVMediaTypeAudio];

  [self.audioCaptureSession startRunning];

  [audioInput release];
  [audioOutput release];

  self.sourceName           = name;
  self.samplesArrivedSignal = [[NSCondition alloc] init];
  TPCircularBufferInit(&self->audioSampleBuffer, kBufferLength);

  return 0;
}

- (void)captureOutput:(AVCaptureOutput *)output
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
  if(connection == self.audioConnection) {
    AudioBufferList audioBufferList;
    CMBlockBufferRef blockBuffer;

    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, NULL, &audioBufferList, sizeof(audioBufferList), NULL, NULL, 0, &blockBuffer);

    //NSAssert(audioBufferList.mNumberBuffers == 1, @"Expected interlveaved PCM format but buffer contained %u streams", audioBufferList.mNumberBuffers);

    // this is safe, because an interleaved PCM stream has exactly one buffer
    // and we don't want to do sanity checks in a performance critical exec path
    AudioBuffer audioBuffer = audioBufferList.mBuffers[0];

    TPCircularBufferProduceBytes(&self->audioSampleBuffer, audioBuffer.mData, audioBuffer.mDataByteSize);
    [self.samplesArrivedSignal signal];
  }
}

@end
