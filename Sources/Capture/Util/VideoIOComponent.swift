//
//  VideoIOComponent.swift
//  AnyImageKit
//
//  Created by 刘栋 on 2019/7/22.
//  Copyright © 2019 AnyImageProject.org. All rights reserved.
//

import UIKit
import AVFoundation
import CoreImage

protocol VideoIOComponentDelegate: class {
    
    func videoIODidCapturePhoto(_ component: VideoIOComponent)
    func videoIO(_ component: VideoIOComponent, didOutput photoData: Data, fileType: FileType)
    func videoIO(_ component: VideoIOComponent, didOutput sampleBuffer: CMSampleBuffer)
}

final class VideoIOComponent: DeviceIOComponent {
    
    weak var delegate: VideoIOComponentDelegate?
    
    private(set) var orientation: DeviceOrientation
    private(set) var position: CapturePosition
    private(set) var flashMode: CaptureFlashMode
    
    private var autoLockFocus: Bool = true
    private var autoLockExposure: Bool = true
    
    private lazy var photoContext: CIContext = {
        if let mtlDevice = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: mtlDevice)
        } else {
            return CIContext()
        }
    }()
    private lazy var photoOutput: AVCapturePhotoOutput = AVCapturePhotoOutput()
    private lazy var videoOutput: AVCaptureVideoDataOutput = AVCaptureVideoDataOutput()
    private let workQueue = DispatchQueue(label: "org.AnyImageProject.AnyImageKit.DispatchQueue.VideoCapture")
    
    private let options: CaptureParsedOptionsInfo
    
    init(session: AVCaptureSession, options: CaptureParsedOptionsInfo) {
        self.options = options
        self.orientation = .portrait
        self.position = options.preferredPositions.first ?? .back
        self.flashMode = options.flashMode
        super.init()
        do {
            // Add device input
            try setupInput(session: session)
            
            // Add photo output, if needed
            setupPhotoOutput(session: session)
            
            // Add video output, if needed
            setupVideoOutput(session: session)
        } catch {
            _print(error)
        }
        addNotifications()
    }
    
    deinit {
        if let camera = device {
            camera.removeObserver(self, forKeyPath: #keyPath(AVCaptureDevice.isAdjustingFocus))
            camera.removeObserver(self, forKeyPath: #keyPath(AVCaptureDevice.isAdjustingExposure))
        }
        removeNotifications()
    }
    
    private func addNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(deviceSubjectAreaDidChange(_:)), name: .AVCaptureDeviceSubjectAreaDidChange, object: nil)
    }
    
    private func removeNotifications() {
        NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceSubjectAreaDidChange, object: nil)
    }
    
    private func setupInput(session: AVCaptureSession) throws {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                                mediaType: .video,
                                                                position: position.rawValue)
        guard let camera = discoverySession.devices.first else {
            _print("Can't find the specified video device")
            return
        }
        if let oldCamera = device {
            oldCamera.removeObserver(self, forKeyPath: #keyPath(AVCaptureDevice.isAdjustingFocus))
            oldCamera.removeObserver(self, forKeyPath: #keyPath(AVCaptureDevice.isAdjustingExposure))
        }
        self.device = camera
        
        let (preset, formats) = camera.preferredFormats(for: options.preferredPreset)
        guard let format = formats.last else {
            _print("Can't find any available format")
            return
        }
        _print("Use preset=\(preset), format=\(format)")
        if let oldInput = self.input {
            session.removeInput(oldInput)
            self.input = nil
        }
        let input = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(input) {
            session.addInput(input)
            self.input = input
        } else {
            _print("Can't add video device input")
        }
        
        // config after add input
        updateProperty { camera in
            camera.isSubjectAreaChangeMonitoringEnabled = true
            if camera.isSmoothAutoFocusSupported {
                camera.isSmoothAutoFocusEnabled = true
            }
            // set format
            camera.activeFormat = format
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(preset.frameRate))
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(preset.frameRate))
            // set keyPath observer
            camera.addObserver(self, forKeyPath: #keyPath(AVCaptureDevice.isAdjustingFocus), options: [.old, .new], context: nil)
            camera.addObserver(self, forKeyPath: #keyPath(AVCaptureDevice.isAdjustingExposure), options: [.old, .new], context: nil)
        }
    }
    
    private func setupPhotoOutput(session: AVCaptureSession) {
        guard session.canAddOutput(photoOutput) else {
            _print("Can't add photo output")
            return
        }
        photoOutput.isHighResolutionCaptureEnabled = true
        // TODO: add live photo support
        photoOutput.isLivePhotoCaptureEnabled = false //photoOutput.isLivePhotoCaptureSupported
        session.addOutput(photoOutput)
        
        setupOutputConnection(photoOutput)
    }
    
    private func setupVideoOutput(session: AVCaptureSession) {
        guard session.canAddOutput(videoOutput) else {
            _print("Can't add video output")
            return
        }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey : kCVPixelFormatType_32BGRA] as [String : Any]
        videoOutput.setSampleBufferDelegate(self, queue: workQueue)
        session.addOutput(videoOutput)
        
        setupOutputConnection(videoOutput)
    }
    
    private func setupOutputConnection(_ output: AVCaptureOutput) {
        // setup connection
        if let connection = output.connection(with: .video) {
            // Set video mirrored
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = position == .front
            }
            // Set video orientation
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            // Set video stabilization
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .cinematic
            }
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        switch keyPath {
        case #keyPath(AVCaptureDevice.isAdjustingFocus):
            if let newValue = change?[.newKey] as? Bool, let oldValue = change?[.oldKey] as? Bool {
                if oldValue, !newValue { // isAdjustingFocus: true -> false
                    setFocus(mode: .locked)
                }
            }
        case #keyPath(AVCaptureDevice.isAdjustingExposure):
            if let newValue = change?[.newKey] as? Bool, let oldValue = change?[.oldKey] as? Bool  {
                if oldValue, !newValue { // isAdjustingExposure: true -> false
                    setExposure(mode: .locked)
                }
            }
        default:
            break
        }
    }
}

// MARK: - Actions
extension VideoIOComponent {
    
    @objc private func deviceSubjectAreaDidChange(_ sender: Notification) {
        setFocus(point: CGPoint(x: 0.5, y: 0.5))
        setExposure(point: CGPoint(x: 0.5, y: 0.5))
    }
}

// MARK: - Writer Settings
extension VideoIOComponent {
    
    var recommendedWriterSettings: [String: Any]? {
        return videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mp4)
    }
}

// MARK: - Camera Setup
extension VideoIOComponent {
    
    func switchCamera(session: AVCaptureSession) {
        position.toggle()
        do {
            try setupInput(session: session)
            setupOutputConnection(photoOutput)
            setupOutputConnection(videoOutput)
        } catch {
            _print(error)
        }
    }
}

// MARK: - Zoom
extension VideoIOComponent {
    
}

// MARK: - Foucs
extension VideoIOComponent {
    
    func setFocus(mode: AVCaptureDevice.FocusMode) {
        updateProperty { camera in
            if camera.isFocusModeSupported(mode) {
                camera.focusMode = mode
            }
        }
    }
    
    func setFocus(point: CGPoint) {
        updateProperty { camera in
            if camera.isFocusPointOfInterestSupported {
                camera.focusPointOfInterest = point
            }
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
        }
    }
}

// MARK: - Exposure
extension VideoIOComponent {
    
    func setExposure(mode: AVCaptureDevice.ExposureMode) {
        updateProperty { camera in
            if camera.isExposureModeSupported(mode) {
                camera.exposureMode = mode
            }
        }
    }
    
    func setExposure(point: CGPoint) {
        updateProperty { camera in
            if camera.isExposurePointOfInterestSupported {
                camera.exposurePointOfInterest = point
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
        }
    }
    
    var maxExposureTargetBias: Float {
        return device?.maxExposureTargetBias ?? 0
    }

    var minExposureTargetBias: Float {
        return device?.minExposureTargetBias ?? 0
    }
    
    var exposureTargetBias: Float {
        return device?.exposureTargetBias ?? 0
    }
    
    func setExposure(bias: Float) {
        updateProperty { camera in
            camera.setExposureTargetBias(bias, completionHandler: nil)
        }
    }
}

extension VideoIOComponent {
    
    func setWhiteBalance(mode: AVCaptureDevice.WhiteBalanceMode) {
        updateProperty { camera in
            if camera.isWhiteBalanceModeSupported(mode) {
                camera.whiteBalanceMode = mode
            }
        }
    }
}

// MARK: - Photo
extension VideoIOComponent {
    
    func capturePhoto(orientation: DeviceOrientation) {
        self.orientation = orientation
        let settings = AVCapturePhotoSettings()
        settings.flashMode = flashMode.rawValue
        #if !targetEnvironment(macCatalyst)
        settings.isAutoStillImageStabilizationEnabled = photoOutput.isStillImageStabilizationSupported
        #endif
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension VideoIOComponent: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        delegate?.videoIO(self, didOutput: sampleBuffer)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension VideoIOComponent: AVCapturePhotoCaptureDelegate {
    
    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        delegate?.videoIODidCapturePhoto(self)
    }
    
    // for iOS 11+
    @available(iOS 11.0, *)
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let photoData = photo.fileDataRepresentation() else { return }
        export(photoData: photoData)
    }
    
    #if !targetEnvironment(macCatalyst)
    // for iOS 10
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photoSampleBuffer: CMSampleBuffer?, previewPhoto previewPhotoSampleBuffer: CMSampleBuffer?, resolvedSettings: AVCaptureResolvedPhotoSettings, bracketSettings: AVCaptureBracketedStillImageSettings?, error: Error?) {
        guard let photoSampleBuffer: CMSampleBuffer = photoSampleBuffer else { return }
        guard let photoData = AVCapturePhotoOutput.jpegPhotoDataRepresentation(forJPEGSampleBuffer: photoSampleBuffer, previewPhotoSampleBuffer: previewPhotoSampleBuffer) else { return }
        export(photoData: photoData)
    }
    #endif
    
    private func export(photoData: Data) {
        guard let source = CGImageSourceCreateWithData(photoData as CFData, nil) else { return }
        guard let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return }
        // Orient to up
        guard let cgOrientation = metadata[kCGImagePropertyOrientation as String] as? Int32 else { return }
        guard let orientedImage: CIImage = CIImage(data: photoData)?.oriented(forExifOrientation: cgOrientation) else { return }
        // fixed capture orientation
        let fixedImage = orientedImage.oriented(forExifOrientation: orientation.exifOrientation)
        // Crop to expected aspect ratio
        let size = fixedImage.extent.size
        let aspectRatio = options.photoAspectRatio.cropValue
        let rect: CGRect
        switch orientation {
        case .portrait, .portraitUpsideDown:
            rect = CGRect(x: 0, y: size.height*(1-aspectRatio)/2, width: size.width, height: size.height*aspectRatio)
        case .landscapeLeft, .landscapeRight:
            rect = CGRect(x: size.width*(1-aspectRatio)/2, y: 0, width: size.width*aspectRatio, height: size.height)
        }
        let croppedImage: CIImage = fixedImage.cropped(to: rect)
        guard let cgImage: CGImage = photoContext.createCGImage(croppedImage, from: rect) else { return }
        // Output
        guard let photoData = cgImage.jpegData(compressionQuality: 1.0) else { return }
        delegate?.videoIO(self, didOutput: photoData, fileType: .jpeg)
    }
}