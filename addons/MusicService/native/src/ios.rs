#![allow(deprecated)]

use std::cell::RefCell;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send};
use objc2_avf_audio::{AVAudioSession, AVAudioSessionCategoryPlayback};
use objc2_foundation::{
    NSArray, NSData, NSObject, NSObjectProtocol, NSString, NSURL, NSURLBookmarkCreationOptions,
    NSURLBookmarkResolutionOptions,
};
use objc2_ui_kit::{
    UIApplication, UIDocumentPickerDelegate, UIDocumentPickerMode, UIDocumentPickerViewController,
};

use crate::library::folders::Folder;

type Deliver = Box<dyn FnOnce(Option<Folder>)>;

thread_local! {
    static PICKER: RefCell<Option<Retained<Picker>>> = const { RefCell::new(None) };
}

define_class!(
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[ivars = RefCell<Option<Deliver>>]
    struct Picker;

    unsafe impl NSObjectProtocol for Picker {}

    unsafe impl UIDocumentPickerDelegate for Picker {
        #[unsafe(method(documentPicker:didPickDocumentsAtURLs:))]
        fn picked(&self, _controller: &UIDocumentPickerViewController, urls: &NSArray<NSURL>) {
            self.finish(urls.firstObject().and_then(|url| folder_of(&url)));
        }

        #[unsafe(method(documentPickerWasCancelled:))]
        fn cancelled(&self, _controller: &UIDocumentPickerViewController) {
            self.finish(None);
        }
    }
);

impl Picker {
    fn new(mtm: MainThreadMarker, deliver: Deliver) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(RefCell::new(Some(deliver)));
        unsafe { msg_send![super(this), init] }
    }

    fn finish(&self, folder: Option<Folder>) {
        if let Some(deliver) = self.ivars().borrow_mut().take() {
            deliver(folder);
        }
        PICKER.with(|picker| picker.borrow_mut().take());
    }
}

pub fn start_audio_session() {
    unsafe {
        let session = AVAudioSession::sharedInstance();
        if let Some(category) = AVAudioSessionCategoryPlayback {
            let _ = session.setCategory_error(category);
        }
        let _ = session.setActive_error(true);
    }
}

pub fn pick_folder(deliver: impl FnOnce(Option<Folder>) + 'static) {
    let Some(mtm) = MainThreadMarker::new() else {
        return deliver(None);
    };
    let Some(root) = UIApplication::sharedApplication(mtm)
        .keyWindow()
        .and_then(|window| window.rootViewController())
    else {
        return deliver(None);
    };
    let types = NSArray::from_retained_slice(&[NSString::from_str("public.folder")]);
    let controller = UIDocumentPickerViewController::initWithDocumentTypes_inMode(
        UIDocumentPickerViewController::alloc(mtm),
        &types,
        UIDocumentPickerMode::Open,
    );
    let picker = Picker::new(mtm, Box::new(deliver));
    controller.setDelegate(Some(ProtocolObject::from_ref(&*picker)));
    PICKER.with(|slot| slot.replace(Some(picker)));
    root.presentViewController_animated_completion(&controller, true, None);
}

pub fn resume(folder: &Folder) {
    let Ok(bookmark) = STANDARD.decode(&folder.document_id) else {
        return;
    };
    let data = NSData::with_bytes(&bookmark);
    let url = unsafe {
        NSURL::URLByResolvingBookmarkData_options_relativeToURL_bookmarkDataIsStale_error(
            &data,
            NSURLBookmarkResolutionOptions::empty(),
            None,
            std::ptr::null_mut(),
        )
    };
    if let Ok(url) = url {
        unsafe { url.startAccessingSecurityScopedResource() };
    }
}

fn folder_of(url: &NSURL) -> Option<Folder> {
    unsafe { url.startAccessingSecurityScopedResource() };
    let bookmark = url
        .bookmarkDataWithOptions_includingResourceValuesForKeys_relativeToURL_error(
            NSURLBookmarkCreationOptions::empty(),
            None,
            None,
        )
        .ok()?;
    let mut folder = Folder::of(&url.to_file_path()?);
    folder.document_id = STANDARD.encode(bookmark.to_vec());
    Some(folder)
}
