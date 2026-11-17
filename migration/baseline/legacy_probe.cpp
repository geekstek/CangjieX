#include <unistd.h>
#include "OVIMGeneric.h"
#include "OVAFAssociatedPhrase.h"
#include "OVOFHanConvert.h"
#include "OVAFBopomofoCorrection.h"
#include <PlainVanilla/PVBasicKeyValueMapImpl.h>
#include <PlainVanilla/PVCandidate.h>
#include <PlainVanilla/PVLoaderService.h>
#include <PlainVanilla/PVTextBuffer.h>
#include <iostream>
#include <memory>
#include <stdexcept>

using namespace OpenVanilla;

static std::string json(const std::string& text) {
    std::string result = "\"";
    for (unsigned char character : text) {
        if (character == '"' || character == '\\') {
            result += '\\';
            result += character;
        } else if (character < 32) {
            const char* digits = "0123456789abcdef";
            result += "\\u00";
            result += digits[character >> 4];
            result += digits[character & 15];
        } else {
            result += character;
        }
    }
    return result + "\"";
}

int main(int argc, char** argv) {
    if (argc < 3) {
        std::cerr << "usage: legacy-probe <baseline-db> <event>...\n";
        return 1;
    }
    if (std::string(argv[1]) == "--convert") {
        OVOFTC2SCContext filter;
        std::cout << filter.filterText(argv[2], 0);
        return 0;
    }
    std::unique_ptr<OVSQLiteDatabaseService> database(OVSQLiteDatabaseService::Create(argv[1]));
    if (!database) {
        return 1;
    }
    PVLoaderService loader("zh_TW", 0, database.get());
    bool simplex = std::string(argv[2]).find("--simplex") == 0;
    bool correction = std::string(argv[2]) == "--correction";
    OVIMGeneric module(simplex ? "Generic-simplex-cin" : "Generic-cj-cin", database.get());
    OVPathInfo paths;
    // An empty writable path and disabled learning keep all user data untouched.
    bool full = std::string(argv[2]).find("--full=") == 0 || std::string(argv[2]).find("--simplex-full=") == 0;
    bool live = full || std::string(argv[2]).find("--live=") == 0;
    paths.writablePath = live ? std::string(argv[2]).substr(std::string(argv[2]).find('=') + 1) : "";
    if (!module.initialize(&paths, &loader)) {
        return 1;
    }
    PVBasicKeyValueMapImpl configImpl;
    OVKeyValueMap config(&configImpl);
    config.setKeyBoolValue("UseDynamicFrequency", live);
    if (live) {
        config.setKeyBoolValue("ComposeWhileTyping", true);
        config.setKeyBoolValue("ShouldCommitAtMaximumRadicalLength", true);
        config.setKeyBoolValue("ClearReadingBufferAtCompositionError", false);
        config.setKeyStringValue("UseOverrideTable", "Punctuations-cj-halfwidth-cin");
    }
    module.loadConfig(&config, &loader);
    std::unique_ptr<OVEventHandlingContext> context(module.createContext());
    context->startSession(&loader);
    PVTextBuffer reading, composing;
    PVCandidateService candidates(&loader);
    auto* panel = static_cast<PVOneDimensionalCandidatePanel*>(candidates.useOneDimensionalCandidatePanel());
    panel->reset();
    OVAFAssociatedPhrase associated;
    std::unique_ptr<OVEventHandlingContext> associatedContext;
    OVOFTC2SCContext conversion;
    OVAFBopomofoCorrection correctionModule;
    std::unique_ptr<OVEventHandlingContext> correctionContext;
    if (correction) {
        loader.setCINDatabaseService(database.get());
        if (!correctionModule.initialize(&paths, &loader)) { return 1; }
        correctionContext.reset(correctionModule.createContext());
        correctionContext->startSession(&loader);
    }
    if (full) {
        if (!associated.initialize(&paths, &loader)) { return 1; }
        associatedContext.reset(associated.createContext());
        associatedContext->startSession(&loader);
    }

    for (int argument = (live || simplex || correction) ? 3 : 2; argument < argc; ++argument) {
        std::string event(argv[argument]);
        int code = 0;
        bool command = false, shift = false;
        if (event == "space") { code = OVKeyCode::Space; }
        else if (event == "return") { code = OVKeyCode::Return; }
        else if (event == "backspace") { code = OVKeyCode::Backspace; }
        else if (event == "escape") { code = OVKeyCode::Esc; }
        else if (event == "down") { code = OVKeyCode::Down; }
        else if (event == "up") { code = OVKeyCode::Up; }
        else if (event == "next") { code = OVKeyCode::PageDown; }
        else if (event == "previous") { code = OVKeyCode::PageUp; }
        else if (event.size() == 5 && event.substr(0, 4) == "cmd:") { code = event[4]; command = true; }
        else if (event.size() == 7 && event.substr(0, 6) == "shift:") { code = event[6]; shift = true; }
        else if (correction && event.find("text:") == 0) { code = 0; }
        else if (event.size() == 1) { code = static_cast<unsigned char>(event[0]); }
        else { throw std::runtime_error("unknown event: " + event); }

        loader.resetState();
        composing.finishCommit();
        OVKey key = loader.makeOVKey(code, false, false, false, shift, command);
        OVEventHandlingContext* active = correction ? correctionContext.get() : context.get();
        bool handled = correction && event.find("text:") == 0
            && correctionContext->handleDirectText(event.substr(5), &reading, &composing, &candidates, &loader);
        bool direct = correction && event.find("text:") == 0;
        handled = handled || (full && !panel->isInControl()
            && associatedContext->handleKey(&key, &reading, &composing, &candidates, &loader));
        if (!handled && !direct) {
        // Mirror PVLoaderSystem.h candidate dispatch; run the original module
        // and panel implementations rather than reimplement their input rules.
        if (panel->isInControl()) {
            auto state = panel->handleKeyEvent(key, &loader);
            if (state == PVCandidateState::CandidateChosen) {
                std::string text = panel->chosenCandidateString();
                size_t index = panel->chosenCandidateIndex();
                panel->stopControl();
                active->candidateSelected(&candidates, text, index, &reading, &composing, &loader);
                panel->reset();
                handled = true;
            } else if (state == PVCandidateState::Canceled) {
                panel->stopControl();
                active->candidateCanceled(&candidates, &reading, &composing, &loader);
                panel->reset();
                handled = true;
            } else if (state == PVCandidateState::Ignored) {
                handled = active->candidateNonPanelKeyReceived(&candidates, &key, &reading, &composing, &loader);
                if (!handled) {
                    loader.beep();
                    handled = true;
                }
                if (!panel->isInControl()) { panel->reset(); }
            } else {
                if (state == PVCandidateState::InvalidCandidateKey || state == PVCandidateState::ReachedPageBoundary) {
                    loader.beep();
                }
                handled = true;
            }
        } else {
            handled = active->handleKey(&key, &reading, &composing, &candidates, &loader);
        }
        }
        if (full && composing.composedCommittedText().size()) {
            std::string text = composing.composedCommittedText();
            composing.finishCommit();
            if (!associatedContext->handleDirectText(text, &reading, &composing, &candidates, &loader)) {
                composing.setComposedCommittedText(text);
            }
            composing.setComposedCommittedText(conversion.filterText(composing.composedCommittedText(), &loader));
        }
        std::cout << "{\"event\":" << json(event)
                  << ",\"handled\":" << (handled ? "true" : "false")
                  << ",\"reading\":" << json(reading.composedText())
                  << ",\"committed\":" << json(composing.composedCommittedText())
                  << ",\"beep\":" << (loader.shouldBeep() ? "true" : "false")
                  << ",\"visible\":" << (panel->isVisible() ? "true" : "false")
                  << ",\"page\":" << panel->currentPage()
                  << ",\"highlight\":" << panel->currentHightlightIndex()
                  << ",\"candidates\":[";
        if (panel->isVisible()) {
            for (size_t index = 0; index < panel->candidateList()->size(); ++index) {
                if (index) { std::cout << ','; }
                std::cout << json(panel->candidateList()->candidateAtIndex(index));
            }
        }
        std::cout << "]";
        if (correction) {
            std::cout << ",\"composing\":" << json(composing.composedText())
                      << ",\"cursor\":" << composing.cursorPosition();
        }
        std::cout << "}\n";
    }
    context->stopSession(&loader);
}
