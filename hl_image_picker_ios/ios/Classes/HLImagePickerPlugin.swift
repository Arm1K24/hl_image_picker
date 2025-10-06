import Flutter
import Photos
import UIKit
import TLPhotoPicker
import CropViewController
import MobileCoreServices

enum PickerType {
    case picker
    case camera
    case cropper
}

public class HLImagePickerPlugin: NSObject, FlutterPlugin, TLPhotosPickerViewControllerDelegate, CropViewControllerDelegate, UIImagePickerControllerDelegate & UINavigationControllerDelegate {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "hl_image_picker", binaryMessenger: registrar.messenger())
        let instance = HLImagePickerPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    var arguments: NSDictionary? = nil
    var uiStyle: [String: Any]? = nil
    var result: FlutterResult? = nil
    var croppedImages: [[String : Any]] = []
    
    var configure = TLPhotosPickerConfigure()
    var selectedAssets = [TLPHAsset]()
    var pickerType: PickerType? = nil
    
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "openPicker":
            self.pickerType = PickerType.picker
            self.arguments = call.arguments as? NSDictionary
            uiStyle = arguments?["localized"] as? [String: Any]
            self.croppedImages = []
            self.result = result
            self.initConfig()
            self.openPicker()
            
        case "openCamera":
            self.pickerType = PickerType.camera
            self.arguments = call.arguments as? NSDictionary
            uiStyle = arguments?["localized"] as? [String: Any]
            self.result = result
            self.openCamera()
            
        case "openCropper":
            self.pickerType = PickerType.cropper
            self.arguments = call.arguments as? NSDictionary
            uiStyle = arguments?["localized"] as? [String: Any]
            self.result = result
            if let imagePath = self.arguments?["imagePath"] as? String,
               let imagePathEncode = imagePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let imageUrl = URL(string: "file://" + imagePathEncode),
               let imageData = try? Data(contentsOf: imageUrl),
               let image = UIImage(data: imageData) {
                self.openCropper(image: image)
            } else {
                result(FlutterError(code: "INVALID_PATH", message: "Invalid path", details: nil))
            }
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: Camera
    
    private func openCamera() {
        if UIImagePickerController.isSourceTypeAvailable(UIImagePickerController.SourceType.camera) {
            DispatchQueue.main.async {
                HLImagePickerUtils.checkCameraPermission { granted in
                    if granted {
                        DispatchQueue.main.async {
                            let imagePicker = UIImagePickerController()
                            imagePicker.delegate = self
                            imagePicker.sourceType = .camera
                            imagePicker.allowsEditing = false
                            if self.arguments?["cameraType"] as? String == "video" {
                                imagePicker.mediaTypes = [kUTTypeMovie as String]
                                imagePicker.videoQuality = .typeHigh
                                if let recordVideoMaxSecond = self.arguments?["recordVideoMaxSecond"] as? Int {
                                    imagePicker.videoMaximumDuration = TimeInterval(recordVideoMaxSecond)
                                }
                            }
                            UIApplication.topViewController()?.present(imagePicker, animated: true, completion: nil)
                        }
                    } else {
                        self.result!(FlutterError(code: "CAMERA_PERMISSION_DENIED", message: "Camera permission denied", details: nil))
                    }
                }
            }
        } else {
            result!(FlutterError(code: "CAMERA_NOT_AVAILABLE", message: "Camera is not available", details: nil))
        }
    }
    
    public func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let isVideo = arguments?["cameraType"] as? String == "video"
        if isVideo {
            if let videoURL = info[.mediaURL] as? URL {
                let asset = AVAsset(url: videoURL)
                let pathStr = videoURL.absoluteString.replacingOccurrences(of: "file://", with: "")
                let videoSize = HLImagePickerUtils.getVideoSize(asset: asset)
                let mimeType = HLImagePickerUtils.getMimeType(url: videoURL)
                var media = [
                    "path": pathStr,
                    "id": pathStr,
                    "name": videoURL.lastPathComponent,
                    "mimeType": mimeType ?? "",
                    "width": Int(videoSize.width) as NSNumber,
                    "height": Int(videoSize.height) as NSNumber,
                    "duration": asset.duration.seconds,
                    "size": HLImagePickerUtils.getFileSize(at: videoURL.path),
                    "type": "video"
                ] as [String : Any]
                let isGenerateThumbnail = arguments?["isExportThumbnail"] as? Bool ?? false
                if isGenerateThumbnail {
                    let compressQuality = arguments?["thumbnailCompressQuality"] as? Double
                    let compressFormat = arguments?["thumbnailCompressFormat"] as? String
                    media["thumbnail"] = HLImagePickerUtils.generateVideoThumbnail(from: videoURL ,quality: compressQuality, format: compressFormat)
                }
                result!(media)
            }
            
            picker.dismiss(animated: true, completion: nil)
        } else {
            let isCropEnabled = arguments?["cropping"] as? Bool ?? false
            if let image = info[.originalImage] as? UIImage {
                if isCropEnabled {
                    openCropper(image: image)
                } else {
                    let compressQuality = arguments?["cameraCompressQuality"] as? Double
                    let compressFormat = arguments?["cameraCompressFormat"] as? String
                    var targetSize: CGSize?
                    if let cameraMaxWidth = arguments?["cameraMaxWidth"] as? Int,
                       let cameraMaxHeight = arguments?["cameraMaxHeight"] as? Int {
                        targetSize = CGSize(width: CGFloat(cameraMaxWidth), height: CGFloat(cameraMaxHeight))
                    }
                    let imageData = HLImagePickerUtils.copyImage(image, quality: compressQuality, format: compressFormat, targetSize: targetSize)
                    result!(imageData)
                    picker.dismiss(animated: true, completion: nil)
                }
            } else {
                result!(FlutterError(code: "CAMERA_ERROR", message: "Camera error", details: nil))
                picker.dismiss(animated: true, completion: nil)
            }
        }
    }
    
    public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true, completion: nil)
        self.result!(FlutterError(code: "CANCELED", message: "User has canceled the camera", details: nil))
    }
    
    // MARK: TLPhotoPicker
    
    private func initConfig() {
        configure = TLPhotosPickerConfigure()
        switch arguments?["mediaType"] as? String {
        case "video":
            configure.mediaType = .video
            configure.allowedVideoRecording = true
            configure.allowedPhotograph = false
            configure.recordingVideoQuality = .typeHigh
            break
        case "image":
            configure.mediaType = .image
            configure.allowedVideoRecording = false
            break
        default: break
        }
        let defaultAlbumName = uiStyle?["defaultAlbumName"] as? String ?? "Recents"
        configure.customLocalizedTitle = ["Recents": defaultAlbumName]
        configure.usedCameraButton = arguments?["usedCameraButton"] as? Bool ?? true
        if let maxDuration = arguments?["maxDuration"] as? Int {
            configure.maxVideoDuration = TimeInterval(maxDuration)
        }
        let numberOfColumn = arguments?["numberOfColumn"] as? Int ?? 3
        configure.numberOfColumn = numberOfColumn
        let maxSelectedAssets = arguments?["maxSelectedAssets"] as? Int ?? 1
        configure.maxSelectedAssets = maxSelectedAssets
        configure.singleSelectedMode = maxSelectedAssets == 1
        configure.previewAtForceTouch = arguments?["enablePreview"] as? Bool ?? false
        configure.cancelTitle = uiStyle?["cancelText"] as? String ?? "Cancel"
        configure.doneTitle = uiStyle?["doneText"] as? String ?? "Done"
        configure.tapHereToChange = uiStyle?["tapHereToChangeText"] as? String ?? "Tap here to change"
        configure.emptyMessage = uiStyle?["emptyMediaText"] as? String ?? "No media available"
        
        var newAssets = [TLPHAsset]()
        if let selecteds = arguments?["selectedIds"] as? NSArray {
            for index in 0..<selecteds.count {
                let assetId = selecteds[index] as! String
                var TLAsset = TLPHAsset.asset(with: assetId)
                TLAsset?.selectedOrder = index + 1
                newAssets.insert(TLAsset!, at: index)
            }
        }
        self.selectedAssets = newAssets
    }
    
    private func openPicker() {
        let picker = TLPhotosPickerViewController()
        picker.delegate = self
        picker.configure = configure
        picker.selectedAssets = self.selectedAssets
        DispatchQueue.main.async {
            UIApplication.topViewController()?.present(picker, animated: true, completion: nil)
        }
    }
    
    public func shouldDismissPhotoPicker(withTLPHAssets: [TLPHAsset]) -> Bool {
        return false
    }
    
    public func dismissPhotoPicker(withTLPHAssets: [TLPHAsset]) {
        if let minSelectedAssets = arguments?["minSelectedAssets"] as? Int, withTLPHAssets.count < minSelectedAssets {
            showAlert(message: "minSelectedAssetsErrorText", defaultText: "Need to select at least \(minSelectedAssets)")
            return;
        }
        
        if withTLPHAssets.count == 0 {
            result!([] as NSArray);
            UIApplication.topViewController()?.dismiss(animated: true, completion: nil)
            return;
        }
        
        let isCropEnabled = arguments?["cropping"] as? Bool ?? false
        if (configure.mediaType == .image && isCropEnabled) {
            self.processAssetForCropping(assets: withTLPHAssets)
        } else {
            let loadingAlert = showLoading()
            let group = DispatchGroup()
            var data: Array<NSDictionary> = Array<NSDictionary>()
            let isConvertLivePhoto = arguments?["convertLivePhotosToJPG"] as? Bool ?? true
            let isConvertHeic = arguments?["convertHeicToJPG"] as? Bool ?? false
            let compressQuality = arguments?["compressQuality"] as? Double
            let compressFormat = arguments?["compressFormat"] as? String
            var targetSize: CGSize?
            if let maxWidth = arguments?["maxWidth"] as? Int,
               let maxHeight = arguments?["maxHeight"] as? Int {
                targetSize = CGSize(width: CGFloat(maxWidth), height: CGFloat(maxHeight))
            }
            for asset in withTLPHAssets {
                group.enter()
                let isHeicPhoto = asset.extType() == .heic
                let isLivePhoto = asset.phAsset?.mediaSubtypes.contains(.photoLive) == true
                let isGif = asset.phAsset?.playbackStyle == .imageAnimated
                let isCompressImage = asset.type == .photo && !isGif && (targetSize != nil || compressQuality != nil || compressFormat != nil)
                if (isConvertHeic && isHeicPhoto && !isLivePhoto) || isCompressImage, let uiImage = asset.fullResolutionImage {
                    if let imageInfo = HLImagePickerUtils.copyImage(uiImage, quality: compressQuality, format: compressFormat, targetSize: targetSize, id: asset.phAsset?.localIdentifier) {
                        let media = NSDictionary(dictionary: imageInfo)
                        data.append(media)
                    }
                    group.leave();
                } else {
                    let result = asset.tempCopyMediaFile(exportPreset: AVAssetExportPresetPassthrough, convertLivePhotosToJPG: isConvertLivePhoto, completionBlock: { (filePath, fileType) in
                        let media = NSDictionary(dictionary: self.buildResponse(path: filePath, withType: fileType, withAsset: asset))
                        data.append(media)
                        group.leave();
                    })
                    if result == nil {
                        group.leave();
                    }
                }
            }
            group.notify(queue: .main){ [] in
                loadingAlert.dismiss(animated: true, completion: {
                    UIApplication.topViewController()?.dismiss(animated: true, completion: nil)
                    if data.isEmpty {
                        self.result!(FlutterError(code: "PICKER_ERROR", message: "Picker error", details: nil))
                    }else {
                        self.result!(data);
                    }
                })
            }
        }
    }
    
    private func processAssetForCropping(assets: [TLPHAsset]) {
        if let asset = assets.first, let image = asset.fullResolutionImage {
            self.selectedAssets = Array(assets.dropFirst())
            openCropper(image: image)
        } else {
            UIApplication.topViewController()?.dismiss(animated: true, completion: {
                if self.croppedImages.isEmpty {
                    self.result!(FlutterError(code: "CROP_ERROR", message: "Crop error", details: nil))
                } else {
                    self.result!(self.croppedImages)
                }
            })
        }
    }
    
    public func canSelectAsset(phAsset: PHAsset) -> Bool {
        if phAsset.mediaType == .video {
            if let maxDuration = arguments?["maxDuration"] as? Int, maxDuration > 0 && phAsset.duration > TimeInterval(maxDuration) {
                showAlert(message: "maxDurationErrorText", defaultText: "Exceeded maximum duration of the video")
                return false;
            }
            
            if let minDuration = arguments?["minDuration"] as? Int, minDuration >= 0 && phAsset.duration < TimeInterval(minDuration) {
                showAlert(message: "minDurationErrorText", defaultText: "The video is too short")
                return false;
            }
        }
        
        let isGifSupported = arguments?["isGif"] as? Bool ?? false
        if !isGifSupported && phAsset.playbackStyle == .imageAnimated {
            showAlert(message: "gifErrorText", defaultText: "File type is not supported")
            return false
        }
        
        let assetSize = getAssetSize(asset: phAsset)
        if let maxSize = arguments?["maxFileSize"] as? Double, assetSize > maxSize {
            showAlert(message: "maxFileSizeErrorText", defaultText: "Exceeded maximum file size")
            return false
        }
        
        if let minSize = arguments?["minFileSize"] as? Double, assetSize < minSize {
            showAlert(message: "minFileSizeErrorText", defaultText: "The file size is too small")
            return false
        }
        
        return true
    }

    public func photoPickerDidCancel() {
        self.result!(FlutterError(code: "CANCELED", message: "User has canceled the picker", details: nil))
    }
    
    public func handleNoAlbumPermissions(picker: TLPhotosPickerViewController) {
        picker.dismiss(animated: true) {
            self.showAlert(message: "noAlbumPermissionText", defaultText: "No permission to access album")
        }
    }
    
    public func handleNoCameraPermissions(picker: TLPhotosPickerViewController) {
        showAlert(message: "noCameraPermissionText", defaultText: "No permission to access camera")
    }
    
    public func didExceedMaximumNumberOfSelection(picker: TLPhotosPickerViewController) {
        showAlert(message: "maxSelectedAssetsErrorText", defaultText: "Exceeded maximum number of selected items")
    }
    
    private func getAssetSize(asset: PHAsset) -> Double {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first,
              let unsignedInt64 = resource.value(forKey: "fileSize") as? CLong else {
            return 0
        }
        let sizeOnDisk = Int64(bitPattern: UInt64(unsignedInt64))
        return Double(sizeOnDisk / 1024)
    }
    
    private func buildResponse(path: URL, withType type: String, withAsset asset: TLPHAsset ) -> [String : Any] {
        let phAsset = asset.phAsset
        var media = [
            "path": path.absoluteString.replacingOccurrences(of: "file://", with: ""),
            "id": phAsset?.localIdentifier ?? "",
            "name": asset.originalFileName ?? "",
            "mimeType": type ,
            "width": Int(phAsset?.pixelWidth ?? 0) as NSNumber,
            "height": Int(phAsset?.pixelHeight ?? 0) as NSNumber,
        ] as [String : Any]
        if phAsset?.mediaType == .video {
            media["type"] = "video"
            asset.videoSize { mediaSize in
                media["size"] = mediaSize
            }
            let isGenerateThumbnail = arguments?["isExportThumbnail"] as? Bool ?? false
            if isGenerateThumbnail {
                let compressQuality = arguments?["thumbnailCompressQuality"] as? Double
                let compressFormat = arguments?["thumbnailCompressFormat"] as? String
                media["thumbnail"] = HLImagePickerUtils.generateVideoThumbnail(from: path ,quality: compressQuality, format: compressFormat)
            }
            media["duration"] = phAsset?.duration ?? 0
        } else {
            media["type"] = "image"
            asset.photoSize { mediaSize in
                media["size"] = mediaSize
            }
        }
        return media
    }
    
    private func showAlert(message: String, defaultText: String? = "") {
        let alert = UIAlertController(title: "", message: uiStyle?[message] as? String ?? defaultText, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: uiStyle?["okText"] as? String ?? "OK", style: .default, handler: nil))
        UIApplication.topViewController()?.present(alert, animated: true, completion: nil)
    }
    
    private func showLoading() -> UIAlertController {
        let alertController = UIAlertController(title: nil, message: uiStyle?["loadingText"] as? String ?? "Loading...", preferredStyle: .alert)
        var indicatorStyle: UIActivityIndicatorView.Style
        if #available(iOS 13.0, *) {
            indicatorStyle  = .large
        } else {
            indicatorStyle = .gray
        }
        let activityIndicator = UIActivityIndicatorView(style: indicatorStyle)
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.startAnimating()
        alertController.view.addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            activityIndicator.leadingAnchor.constraint(equalTo: alertController.view.leadingAnchor, constant: 20),
            activityIndicator.centerYAnchor.constraint(equalTo: alertController.view.centerYAnchor)
        ])
        UIApplication.topViewController()?.present(alertController, animated: true, completion: nil)
        return alertController
    }
    
    // MARK: CropViewController
    private func openCropper(image: UIImage) {
        var cropViewController = CropViewController(croppingStyle: .default, image: image)
        if let croppingStyle = arguments?["croppingStyle"] as? String, croppingStyle == "circular" {
            cropViewController = CropViewController(croppingStyle: .circular, image: image)
        }
        cropViewController.delegate = self
        cropViewController.doneButtonTitle = uiStyle?["cropDoneText"] as? String ?? "Done"
        cropViewController.cancelButtonTitle = uiStyle?["cropCancelText"] as? String ?? "Cancel"
        if let cropTitle = uiStyle?["cropTitleText"] as? String {
            cropViewController.title = cropTitle
        }
        
        if let aspectRatioX = arguments?["ratioX"] as? Double,
           let aspectRatioY = arguments?["ratioY"] as? Double {
            
            // Создаём свой пресет с кастомным размером
            let customPreset = TOCropViewControllerAspectRatioPreset(
                size: CGSize(width: aspectRatioX, height: aspectRatioY),
                title: "\(Int(aspectRatioX)):\(Int(aspectRatioY))"
            )
            
            cropViewController.allowedAspectRatios = [customPreset]
            cropViewController.defaultAspectRatio = customPreset
            
            cropViewController.resetAspectRatioEnabled = false
            cropViewController.aspectRatioPickerButtonHidden = true
            cropViewController.aspectRatioLockDimensionSwapEnabled = true
            cropViewController.aspectRatioLockEnabled = true
        }

        
        // ✅ Новый API для allowedAspectRatios
        if let aspectRatioPresets = arguments?["aspectRatioPresets"] as? [String] {
            var allowedAspectRatios = [TOCropViewControllerAspectRatioPreset]()
            for preset in aspectRatioPresets {
                let ratio = parseAspectRatio(name: preset)
                allowedAspectRatios.append(ratio)
            }
            cropViewController.allowedAspectRatios = allowedAspectRatios
        }
        
        DispatchQueue.main.async {
            UIApplication.topViewController()?.present(cropViewController, animated: self.pickerType == .cropper, completion: nil)
        }
    }
    
    // MARK: - Crop delegates
    public func cropViewController(_ cropViewController: CropViewController, didCropToImage image: UIImage, withRect cropRect: CGRect, angle: Int) {
        let compressQuality = arguments?["cropCompressQuality"] as? Double
        let compressFormat = arguments?["cropCompressFormat"] as? String
        var targetSize: CGSize?
        if let cropMaxWidth = arguments?["cropMaxWidth"] as? Int,
           let cropMaxHeight = arguments?["cropMaxHeight"] as? Int {
            targetSize = CGSize(width: CGFloat(cropMaxWidth), height: CGFloat(cropMaxHeight))
        }
        let croppedImage = HLImagePickerUtils.copyImage(image, quality: compressQuality, format: compressFormat, targetSize: targetSize)
        
        DispatchQueue.main.async {
            if(self.pickerType == .camera) {
                UIApplication.topViewController()?.dismiss(animated: false, completion: {
                    UIApplication.topViewController()?.dismiss(animated: true, completion: {
                        if let croppedImage = croppedImage {
                            self.result?(croppedImage)
                        } else {
                            self.result?(FlutterError(code: "CROP_ERROR", message: "Crop error", details: nil))
                        }
                    })
                })
            } else if(self.pickerType == .cropper) {
                UIApplication.topViewController()?.dismiss(animated: true, completion: {
                    if let croppedImage = croppedImage {
                        self.result?(croppedImage)
                    } else {
                        self.result?(FlutterError(code: "CROP_ERROR", message: "Crop error", details: nil))
                    }
                })
            } else {
                if let croppedImage = croppedImage {
                    self.croppedImages.append(croppedImage)
                }
                UIApplication.topViewController()?.dismiss(animated: false, completion: {
                    self.processAssetForCropping(assets: self.selectedAssets)
                })
            }
        }
    }
    
    public func cropViewController(_ cropViewController: CropViewController, didFinishCancelled cancelled: Bool) {
        if cancelled {
            self.croppedImages = []
            DispatchQueue.main.async {
                UIApplication.topViewController()?.dismiss(animated: false, completion: {
                    if self.pickerType == .cropper {
                        self.result?(FlutterError(code: "CANCELED", message: "User has canceled the cropper", details: nil))
                    }
                    if self.pickerType == .camera {
                        UIApplication.topViewController()?.dismiss(animated: true, completion: nil)
                    }
                })
            }
        }
    }
    
    // MARK: - Новый parseAspectRatio
    private func parseAspectRatio(name: String) -> TOCropViewControllerAspectRatioPreset {
        switch name {
        case "square":
            return TOCropViewControllerAspectRatioPreset(size: CGSize(width: 1, height: 1), title: "Square")
        case "3x2":
            return TOCropViewControllerAspectRatioPreset(size: CGSize(width: 3, height: 2), title: "3:2")
        case "4x3":
            return TOCropViewControllerAspectRatioPreset(size: CGSize(width: 4, height: 3), title: "4:3")
        case "5x3":
            return TOCropViewControllerAspectRatioPreset(size: CGSize(width: 5, height: 3), title: "5:3")
        case "5x4":
            return TOCropViewControllerAspectRatioPreset(size: CGSize(width: 5, height: 4), title: "5:4")
        case "7x5":
            return TOCropViewControllerAspectRatioPreset(size: CGSize(width: 7, height: 5), title: "7:5")
        case "16x9":
            return TOCropViewControllerAspectRatioPreset(size: CGSize(width: 16, height: 9), title: "16:9")
        default:
            return TOCropViewControllerAspectRatioPreset(size: .zero, title: "Original")
        }
    }
}

extension UIApplication {
    class func topViewController(base: UIViewController? = UIApplication.shared.keyWindow?.rootViewController) -> UIViewController? {
        if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        if let alert = base as? UIAlertController {
            if let navigationController = alert.presentingViewController as? UINavigationController {
                return navigationController.viewControllers.last
            }
            return alert.presentingViewController
        }
        return base
    }
}
