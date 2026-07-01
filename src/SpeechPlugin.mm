// SpeechPlugin — macOS port
// Original Windows plugin: "Speech" for Notepad++ by Jim Xochellis (GPL v2, 2008).
// Unofficial fork of https://sourceforge.net/projects/npp-plugins/files/SpeechPlugin/
//
// Reads the current document or selection aloud (text-to-speech). Provides:
//   • "Speak Selection" — speak the current selection
//   • "Speak Document"  — speak the whole active document
//   • "Stop Speech"     — stop / purge current speech
//   • "Pause Speech"    — pause playback
//   • "Resume Speech"   — resume after a pause
//   • "Voice & Rate…"   — pick a system voice + speaking rate (macOS value-add)
//
// IMPL-SWAP: the Windows version drives Microsoft SAPI 5 (COM ISpVoice via
// CoCreateInstance(CLSID_SpVoice)). macOS has fully-native text-to-speech in
// AVFoundation, so the whole speech engine is reimplemented on AVSpeechSynthesizer:
//
//   SAPI (Windows)                         AVFoundation (macOS)
//   ──────────────────────────────────     ────────────────────────────────────────
//   CoInitializeEx / CoCreateInstance      [[AVSpeechSynthesizer alloc] init]  (once)
//   ISpVoice::Speak(txt,                    stopSpeakingAtBoundary:Immediate    (purge)
//       SPF_ASYNC|SPF_PURGEBEFORESPEAK)     + speakUtterance: (async by design)
//   ISpVoice::Pause()                       pauseSpeakingAtBoundary:Immediate
//   ISpVoice::Resume()                      continueSpeaking
//   ISpVoice::Release()  (== Stop)          stopSpeakingAtBoundary:Immediate
//   (no voice/rate UI in v0.6)              AVSpeechSynthesisVoice + utterance.rate
//
// The Scintilla text-extraction path (selection range / whole document, UTF-8) is
// ported verbatim; only the platform layer changes (::SendMessage →
// nppData._sendMessage, MessageBox → NSAlert). Voice/rate persist to an INI under
// NPPM_GETPLUGINSCONFIGDIR (the host's per-plugin Config dir).
//
// Host note: AVSpeechSynthesizer is async and owns its own audio playback on a
// background thread, so the "ghost thread" caveat from the Windows source (which
// is why it deliberately skipped Stop() at shutdown) does not apply — we stop
// cleanly on NPPN_SHUTDOWN.

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>

#include <string>
#include <vector>

// ── plugin-wide state ────────────────────────────────────────────────────────
static const char *PLUGIN_NAME = "Speech";
static const int   nbFunc      = 9;   // 7 commands + 2 separators (Speak/Stop/…/About)

NppData  nppData;            // global so the SendMessage() compat macro resolves
FuncItem funcItem[nbFunc];

// The single, long-lived synthesizer (mirrors the original's single gVoice).
static AVSpeechSynthesizer *gSynth = nil;

// ── settings (voice identifier + rate), persisted to INI ─────────────────────
struct SpeechSettings {
    // Empty voiceId → use the system default voice for the current locale.
    std::string voiceId;
    // 0.0 → use AVSpeechUtteranceDefaultSpeechRate; otherwise an explicit 0..1
    // value already clamped to [min,max] by AVSpeechUtterance.
    float rate = 0.0f;
};
static SpeechSettings g_set;

// ── platform helpers ─────────────────────────────────────────────────────────
static NppHandle currentScintilla() {
    int which = 0;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 0) ? nppData._scintillaMainHandle : nppData._scintillaSecondHandle;
}

static intptr_t sci(NppHandle h, uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(h, msg, w, l);
}

static void showAlert(const char *title, const char *msg, NSAlertStyle style) {
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = style;
        alert.messageText = title ? [NSString stringWithUTF8String:title] : @"";
        alert.informativeText = msg ? [NSString stringWithUTF8String:msg] : @"";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}

// ── settings persistence (INI under NPPM_GETPLUGINSCONFIGDIR) ─────────────────
static NSString *configPath() {
    @autoreleasepool {
        char buf[1024] = {0};
        nppData._sendMessage(nppData._nppHandle, NPPM_GETPLUGINSCONFIGDIR,
                             (uintptr_t)sizeof(buf), (intptr_t)buf);
        NSString *cfgRoot = (buf[0] != '\0')
            ? [NSString stringWithUTF8String:buf]
            : [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                  NSUserDomainMask, YES).firstObject
                  stringByAppendingPathComponent:@"Nextpad++/plugins/Config"]
                  copy];
        NSString *dir = [cfgRoot stringByAppendingPathComponent:@"SpeechPlugin"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:nil];
        return [dir stringByAppendingPathComponent:@"SpeechPlugin.ini"];
    }
}

static std::string trim(const std::string &s) {
    size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return "";
    size_t e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

static void loadSettings() {
    @autoreleasepool {
        NSString *content = [NSString stringWithContentsOfFile:configPath()
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
        if (!content) return;  // first run → keep defaults
        for (NSString *raw in [content componentsSeparatedByCharactersInSet:
                                   [NSCharacterSet newlineCharacterSet]]) {
            std::string line = trim(raw.UTF8String);
            if (line.empty() || line[0] == ';' || line[0] == '#' || line[0] == '[')
                continue;
            size_t eq = line.find('=');
            if (eq == std::string::npos) continue;
            std::string key = trim(line.substr(0, eq));
            std::string val = trim(line.substr(eq + 1));
            if (key == "voiceId") g_set.voiceId = val;
            else if (key == "rate") {
                try { g_set.rate = std::stof(val); } catch (...) { g_set.rate = 0.0f; }
            }
        }
    }
}

static void saveSettings() {
    @autoreleasepool {
        std::string s = "[SpeechPlugin]\n";
        s += "voiceId=" + g_set.voiceId + "\n";
        char rateBuf[32];
        snprintf(rateBuf, sizeof(rateBuf), "%g", g_set.rate);
        s += std::string("rate=") + rateBuf + "\n";
        NSString *str = [NSString stringWithUTF8String:s.c_str()];
        [str writeToFile:configPath() atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
    }
}

// ── speech engine (AVSpeechSynthesizer; replaces SAPI ISpVoice) ──────────────
// Resolve the configured voice, falling back to the system default. If a saved
// identifier no longer exists on this machine (voices can be removed), we fall
// back gracefully instead of failing the speak.
static AVSpeechSynthesisVoice *resolveVoice() {
    if (g_set.voiceId.empty()) return nil;  // nil → AVFoundation default voice
    NSString *ident = [NSString stringWithUTF8String:g_set.voiceId.c_str()];
    AVSpeechSynthesisVoice *v = [AVSpeechSynthesisVoice voiceWithIdentifier:ident];
    return v;  // may be nil if the voice was uninstalled → default is used
}

// Speak UTF-8 text. Mirrors SpeekText(): no-op on empty; purge-before-speak so a
// new request interrupts the previous one (SPF_PURGEBEFORESPEAK), then async play.
static void speakText(const std::string &utf8) {
    @autoreleasepool {
        if (utf8.empty()) return;
        NSString *text = [NSString stringWithUTF8String:utf8.c_str()];
        if (!text || text.length == 0) return;

        if (!gSynth) gSynth = [[AVSpeechSynthesizer alloc] init];

        // SPF_PURGEBEFORESPEAK: clear anything queued/playing first.
        [gSynth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];

        AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
        AVSpeechSynthesisVoice *v = resolveVoice();
        if (v) u.voice = v;
        if (g_set.rate > 0.0f) u.rate = g_set.rate;  // else AVFoundation default

        // SPF_ASYNC: speakUtterance: returns immediately; playback runs on the
        // synthesizer's own thread.
        [gSynth speakUtterance:u];
    }
}

// ── core commands (ported from SpeechPlugin.cpp) ─────────────────────────────
static void SpeakDocument() {
    @autoreleasepool {
        NppHandle h = currentScintilla();
        intptr_t txtLen = sci(h, SCI_GETTEXTLENGTH);
        if (txtLen <= 0) return;

        // SCI_GETTEXT wants buffer length incl. NUL; it writes up to len-1 chars.
        std::string buf((size_t)txtLen + 1, '\0');
        sci(h, SCI_GETTEXT, (uintptr_t)buf.size(), (intptr_t)&buf[0]);
        buf.resize((size_t)txtLen);     // drop trailing NUL slack
        speakText(buf);
    }
}

static void SpeakSelection() {
    @autoreleasepool {
        NppHandle h = currentScintilla();
        intptr_t selStart = sci(h, SCI_GETSELECTIONSTART);
        intptr_t selEnd   = sci(h, SCI_GETSELECTIONEND);

        if (selEnd > 0 && selEnd > selStart) {
            std::string buf((size_t)(selEnd - selStart) + 1, '\0');
            Sci_TextRangeFull tr;
            tr.chrg.cpMin = (Sci_Position)selStart;
            tr.chrg.cpMax = (Sci_Position)selEnd;
            tr.lpstrText  = &buf[0];
            sci(h, SCI_GETTEXTRANGEFULL, 0, (intptr_t)&tr);
            buf.resize((size_t)(selEnd - selStart));
            speakText(buf);
        } else {
            showAlert("No selection", "Please select some text first",
                      NSAlertStyleInformational);
        }
    }
}

static void StopSpeech() {
    if (gSynth) [gSynth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
}

static void PauseSpeech() {
    if (gSynth) [gSynth pauseSpeakingAtBoundary:AVSpeechBoundaryImmediate];
}

static void ResumeSpeech() {
    if (gSynth) [gSynth continueSpeaking];
}

// ── Voice & Rate dialog (programmatic AppKit, modal) ─────────────────────────
// macOS value-add: AVSpeechSynthesizer exposes the installed system voices and a
// rate, so we surface a small picker. (The v0.6 Windows plugin had no such UI.)
@interface SPVoiceController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSWindow   *window;
@property(nonatomic, strong) NSPopUpButton *voicePopup;
@property(nonatomic, strong) NSSlider   *rateSlider;
@end

@implementation SPVoiceController {
    NSArray<AVSpeechSynthesisVoice *> *_voices;   // index 0 == "System Default"
}

- (NSTextField *)label:(NSString *)s frame:(NSRect)f to:(NSView *)v {
    NSTextField *t = [NSTextField labelWithString:s];
    t.frame = f;
    [v addSubview:t];
    return t;
}

- (void)build {
    const CGFloat W = 460, H = 200;
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                          styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"Voice & Rate";
    _window.delegate = self;
    _window.releasedWhenClosed = NO;
    NSView *root = _window.contentView;

    [self label:@"Voice:" frame:NSMakeRect(20, H - 52, 60, 20) to:root];
    _voicePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(86, H - 56, W - 106, 26)];
    [root addSubview:_voicePopup];

    // Build the voice list: a "System Default" sentinel + all installed voices,
    // sorted by language then name for a tidy menu.
    NSArray<AVSpeechSynthesisVoice *> *all = [AVSpeechSynthesisVoice speechVoices];
    all = [all sortedArrayUsingComparator:^NSComparisonResult(AVSpeechSynthesisVoice *a,
                                                              AVSpeechSynthesisVoice *b) {
        NSComparisonResult r = [a.language compare:b.language];
        return (r != NSOrderedSame) ? r : [a.name compare:b.name];
    }];
    _voices = all;

    [_voicePopup addItemWithTitle:@"System Default"];
    NSInteger selectIdx = 0;
    for (NSUInteger i = 0; i < all.count; i++) {
        AVSpeechSynthesisVoice *v = all[i];
        NSString *title = [NSString stringWithFormat:@"%@ (%@)", v.name, v.language];
        [_voicePopup addItemWithTitle:title];
        if (!g_set.voiceId.empty() &&
            [v.identifier isEqualToString:[NSString stringWithUTF8String:g_set.voiceId.c_str()]])
            selectIdx = (NSInteger)i + 1;  // +1 for the sentinel at index 0
    }
    [_voicePopup selectItemAtIndex:selectIdx];

    // Rate slider: AVSpeechUtteranceMinimum..Maximum; "0" → use default.
    [self label:@"Rate:" frame:NSMakeRect(20, H - 96, 60, 20) to:root];
    _rateSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(86, H - 98, W - 106, 24)];
    _rateSlider.minValue = AVSpeechUtteranceMinimumSpeechRate;
    _rateSlider.maxValue = AVSpeechUtteranceMaximumSpeechRate;
    _rateSlider.floatValue = (g_set.rate > 0.0f) ? g_set.rate
                                                 : AVSpeechUtteranceDefaultSpeechRate;
    [root addSubview:_rateSlider];
    [self label:@"slower" frame:NSMakeRect(86, H - 120, 60, 16) to:root];
    NSTextField *fast = [self label:@"faster" frame:NSMakeRect(W - 76, H - 120, 56, 16) to:root];
    fast.alignment = NSTextAlignmentRight;

    // Preview / OK / Cancel.
    NSButton *preview = [NSButton buttonWithTitle:@"Preview"
                                           target:self action:@selector(preview:)];
    preview.frame = NSMakeRect(20, 14, 90, 30);
    [root addSubview:preview];

    NSButton *ok = [NSButton buttonWithTitle:@"OK" target:self action:@selector(ok:)];
    ok.frame = NSMakeRect(W - 180, 14, 78, 30);
    ok.keyEquivalent = @"\r";
    [root addSubview:ok];
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.frame = NSMakeRect(W - 96, 14, 78, 30);
    cancel.keyEquivalent = @"\e";
    [root addSubview:cancel];
}

// Read the popup/slider into g_set (without persisting).
- (void)pullIntoSettings {
    NSInteger idx = _voicePopup.indexOfSelectedItem;
    if (idx <= 0 || (NSUInteger)(idx - 1) >= _voices.count) {
        g_set.voiceId.clear();  // "System Default"
    } else {
        g_set.voiceId = _voices[idx - 1].identifier.UTF8String;
    }
    float r = _rateSlider.floatValue;
    // Treat "exactly the default" as "unset" so we don't pin a value the user
    // never deliberately chose.
    g_set.rate = (fabsf(r - AVSpeechUtteranceDefaultSpeechRate) < 0.0001f) ? 0.0f : r;
}

- (void)preview:(id)sender {
    [self pullIntoSettings];
    speakText("This is a preview of the selected voice.");
}

- (void)ok:(id)sender {
    [self pullIntoSettings];
    saveSettings();
    [NSApp stopModal];
}
- (void)cancel:(id)sender { [NSApp stopModal]; }
- (void)windowWillClose:(NSNotification *)n { [NSApp stopModal]; }

- (void)run {
    [self build];
    [self.window center];
    [NSApp runModalForWindow:self.window];
    // Stop any preview still playing when the sheet closes.
    if (gSynth) [gSynth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    [self.window orderOut:nil];
}
@end

static void OpenVoiceSettings() {
    @autoreleasepool {
        SPVoiceController *c = [[SPVoiceController alloc] init];
        [c run];
    }
}

// About — native NSAlert (macOS style).
static void cmdAbout() {
    showAlert("SpeechPlugin",
              "SpeechPlugin for Notepad++ (macOS port)\n"
              "Version 1.0.0\n\n"
              "Reads the current document or selection aloud (text-to-speech).\n\n"
              "Features:\n"
              "- Speak the selection or the whole document\n"
              "- Stop, pause and resume playback\n"
              "- Choose a system voice and speaking rate\n\n"
              "Original Windows plugin by Jim Xochellis (GPL v2)\n"
              "macOS port by Andrey Letov\n"
              "Project home: https://github.com/nextpad-plus-plus-plugins/SpeechPlugin.macos",
              NSAlertStyleInformational);
}

// ── plugin exports ───────────────────────────────────────────────────────────
extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;
    loadSettings();

    memset(funcItem, 0, sizeof(funcItem));
    strncpy(funcItem[0]._itemName, "Speak Selection", NPP_MENU_ITEM_SIZE - 1);
    funcItem[0]._pFunc  = SpeakSelection;
    funcItem[0]._pShKey = nullptr;

    strncpy(funcItem[1]._itemName, "Speak Document", NPP_MENU_ITEM_SIZE - 1);
    funcItem[1]._pFunc  = SpeakDocument;
    funcItem[1]._pShKey = nullptr;

    // Separator (host treats _pFunc == NULL as a separator item).
    funcItem[2]._itemName[0] = '\0';
    funcItem[2]._pFunc  = nullptr;
    funcItem[2]._pShKey = nullptr;

    strncpy(funcItem[3]._itemName, "Stop Speech", NPP_MENU_ITEM_SIZE - 1);
    funcItem[3]._pFunc  = StopSpeech;
    funcItem[3]._pShKey = nullptr;

    strncpy(funcItem[4]._itemName, "Pause Speech", NPP_MENU_ITEM_SIZE - 1);
    funcItem[4]._pFunc  = PauseSpeech;
    funcItem[4]._pShKey = nullptr;

    strncpy(funcItem[5]._itemName, "Resume Speech", NPP_MENU_ITEM_SIZE - 1);
    funcItem[5]._pFunc  = ResumeSpeech;
    funcItem[5]._pShKey = nullptr;

    strncpy(funcItem[6]._itemName, "Voice & Rate...", NPP_MENU_ITEM_SIZE - 1);
    funcItem[6]._pFunc  = OpenVoiceSettings;
    funcItem[6]._pShKey = nullptr;

    // Separator (host treats _pFunc == NULL as a separator item).
    funcItem[7]._itemName[0] = '\0';
    funcItem[7]._pFunc  = nullptr;
    funcItem[7]._pShKey = nullptr;

    strncpy(funcItem[8]._itemName, "About...", NPP_MENU_ITEM_SIZE - 1);
    funcItem[8]._pFunc  = cmdAbout;
    funcItem[8]._pShKey = nullptr;
}

extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) { *nbF = nbFunc; return funcItem; }

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    switch (n->nmhdr.code) {
        case NPPN_SHUTDOWN:
            // Unlike SAPI (where the original skipped Stop() to avoid ghost COM
            // threads), AVSpeechSynthesizer stops cleanly, so halt playback here.
            if (gSynth) {
                [gSynth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
                gSynth = nil;
            }
            break;
        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t m, uintptr_t w, intptr_t l) {
    (void)m; (void)w; (void)l;
    return 1;
}
