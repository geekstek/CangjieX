#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/YahooArchive/KeyKey.git}"
SOURCE_UPSTREAM_COMMIT="${SOURCE_UPSTREAM_COMMIT:-81e05f070c070af65cac21e8da28ca4ff2d58905}"
SOURCE_PATCH_MANIFEST="${SOURCE_PATCH_MANIFEST:-${SCRIPT_DIR}/source-patches/manifest.tsv}"
SOURCE_PROBE_DIR="${SOURCE_PROBE_DIR:-/tmp/CangjieX-upstream-source}"
SOURCE_REPO_DIR="${SOURCE_PROBE_DIR}/KeyKey"
GIT_CMD="${GIT:-git}"
SOURCE_ARCHS="${SOURCE_ARCHS:-arm64 x86_64}"
SOURCE_DEPLOYMENT_TARGET="${SOURCE_DEPLOYMENT_TARGET:-11.0}"
SOURCE_BUILD_APP="${SOURCE_BUILD_APP:-}"
SOURCE_BUILD_LOG="${SOURCE_BUILD_LOG:-${SOURCE_PROBE_DIR}/source-build.log}"
SOURCE_DATABASE_LOG="${SOURCE_DATABASE_LOG:-${SOURCE_PROBE_DIR}/database-cooker.log}"
PROJECT_URL="${PROJECT_URL:-https://github.com/geekstek/CangjieX}"
PREFERENCES_BUNDLE_ID="${PREFERENCES_BUNDLE_ID:-io.github.geekstek.cangjiex.preferences}"
SOURCE_PATCH_IDS=""
APPLIED_SOURCE_PATCHES=""

xcrun_policy_error() {
    local output="$1"

    [[ "${output}" == *"unable to load libxcrun"* ]] \
        || [[ "${output}" == *"library load denied by system policy"* ]]
}

print_xcode_recovery() {
    local tool_name="$1"
    local selected_developer_dir

    selected_developer_dir="$(xcode-select -p 2>/dev/null || true)"

    echo "${tool_name} cannot start because macOS is blocking Xcode's libxcrun.dylib."
    if [[ -n "${selected_developer_dir}" ]]; then
        echo "Selected developer directory: ${selected_developer_dir}"
    fi
    echo
    echo "This is an Xcode installation/system policy issue, not a CangjieX source issue."
    echo
    echo "Try these steps:"
    echo "  1. Open /Applications/Xcode.app once and let it finish any setup."
    echo "  2. Restart macOS, then run: xcodebuild -version"
    echo "  3. If it still fails, reinstall Xcode from Apple."

    if [[ -d /Library/Developer/CommandLineTools ]]; then
        echo
        echo "If you only need package builds for now, you can switch back to Command Line Tools:"
        echo "  sudo xcode-select -s /Library/Developer/CommandLineTools"
    fi
}

git_version_output="$("${GIT_CMD}" --version 2>&1)" || {
    if xcrun_policy_error "${git_version_output}"; then
        print_xcode_recovery "${GIT_CMD}"
        exit 0
    fi

    echo "Unable to run ${GIT_CMD}." >&2
    echo "${git_version_output}" >&2
    exit 1
}

load_source_patch_manifest() {
    [[ -f "${SOURCE_PATCH_MANIFEST}" ]] || {
        echo "Source patch manifest is missing: ${SOURCE_PATCH_MANIFEST}" >&2
        exit 1
    }

    SOURCE_PATCH_IDS="$(awk 'NF && $1 !~ /^#/ { print $1 }' "${SOURCE_PATCH_MANIFEST}")"

    if [[ -z "${SOURCE_PATCH_IDS}" ]]; then
        echo "Source patch manifest has no patch entries: ${SOURCE_PATCH_MANIFEST}" >&2
        exit 1
    fi
}

source_patch_applied() {
    local patch_id="$1"
    local description="$2"

    if ! printf '%s\n' "${SOURCE_PATCH_IDS}" | grep -qx "${patch_id}"; then
        echo "Source patch '${patch_id}' is not registered in ${SOURCE_PATCH_MANIFEST}" >&2
        exit 1
    fi

    APPLIED_SOURCE_PATCHES="${APPLIED_SOURCE_PATCHES}${patch_id}"$'\n'
    echo "Applied source patch [${patch_id}]: ${description}"
    echo
}

print_source_patch_summary() {
    local applied_count

    applied_count="$(printf '%s' "${APPLIED_SOURCE_PATCHES}" | sed '/^$/d' | wc -l | tr -d '[:space:]')"

    echo "Source patch manifest: ${SOURCE_PATCH_MANIFEST}"
    echo "Pinned upstream commit: ${SOURCE_UPSTREAM_COMMIT}"
    echo "Applied registered source patches: ${applied_count}"
    echo
}

checkout_upstream_source() {
    mkdir -p "${SOURCE_PROBE_DIR}"

    if [[ -d "${SOURCE_REPO_DIR}/.git" ]]; then
        "${GIT_CMD}" -C "${SOURCE_REPO_DIR}" fetch --depth 1 origin "${SOURCE_UPSTREAM_COMMIT}"
        "${GIT_CMD}" -C "${SOURCE_REPO_DIR}" reset --hard FETCH_HEAD >/dev/null
        "${GIT_CMD}" -C "${SOURCE_REPO_DIR}" clean -fdx >/dev/null
    else
        rm -rf "${SOURCE_REPO_DIR}"
        "${GIT_CMD}" init -q "${SOURCE_REPO_DIR}"
        "${GIT_CMD}" -C "${SOURCE_REPO_DIR}" remote add origin "${UPSTREAM_REPO}"
        "${GIT_CMD}" -C "${SOURCE_REPO_DIR}" fetch --depth 1 origin "${SOURCE_UPSTREAM_COMMIT}"
        "${GIT_CMD}" -C "${SOURCE_REPO_DIR}" checkout --detach -q FETCH_HEAD
    fi

    local actual_commit
    actual_commit="$("${GIT_CMD}" -C "${SOURCE_REPO_DIR}" rev-parse HEAD)"

    if [[ "${actual_commit}" != "${SOURCE_UPSTREAM_COMMIT}" ]]; then
        echo "Upstream checkout is ${actual_commit}, expected ${SOURCE_UPSTREAM_COMMIT}" >&2
        exit 1
    fi
}

load_source_patch_manifest
checkout_upstream_source

source_root="$(find "${SOURCE_REPO_DIR}" -maxdepth 1 -type d -name 'YahooKeyKey-Source-*' | sort | head -n 1)"

if [[ -z "${source_root}" ]]; then
    echo "Unable to find YahooKeyKey-Source-* in ${SOURCE_REPO_DIR}" >&2
    exit 1
fi

apply_source_compat_patches() {
    local file_helper="${source_root}/Frameworks/OpenVanilla/Headers/OVFileHelper.h"
    local module_system="${source_root}/Frameworks/PlainVanilla/Headers/PVModuleSystem.h"
    local property_list="${source_root}/Frameworks/PlainVanilla/Source/Cocoa/PVPropertyList.mm"
    local nsstring_extension="${source_root}/Loaders/OSX-IMK/NSStringExtension.mm"
    local dictionary_window_source="${source_root}/Loaders/OSX-IMK/CVDictionaryWindow.m"
    local dictionary_controller_header="${source_root}/Loaders/OSX-IMK/CVDictionaryController.h"
    local symbol_controller_header="${source_root}/Loaders/OSX-IMK/CVSymbolController.h"
    local vertical_candidate_header="${source_root}/Loaders/OSX-IMK/CVVerticalCandidateController.h"
    local about_controller_source="${source_root}/Loaders/OSX-IMK/CVAboutController.mm"
    local open_vanilla_loader_header="${source_root}/Loaders/OSX-IMK/OpenVanillaLoader.h"
    local open_vanilla_loader_source="${source_root}/Loaders/OSX-IMK/OpenVanillaLoader.mm"
    local open_vanilla_controller_source="${source_root}/Loaders/OSX-IMK/OpenVanillaController.mm"
    local open_vanilla_config_header="${source_root}/Loaders/OSX-IMK/OpenVanillaConfig.h"
    local open_vanilla_main_source="${source_root}/Loaders/OSX-IMK/main.mm"
    local send_key_source="${source_root}/Loaders/OSX-IMK/CVSendKey.m"
    local loader_user_persistence_mm="${source_root}/Loaders/CrossPlatform/OVLoaderUserPersistence.mm"
    local loader_user_persistence_cpp="${source_root}/Loaders/CrossPlatform/OVLoaderUserPersistence.cpp"
    local bpmf_user_phrase_helper="${source_root}/Frameworks/Manjusri/Source/BPMFUserPhraseHelper.cpp"
    local smart_mandarin_source="${source_root}/ModulePackages/OVIMMandarin/OVIMSmartMandarin.cpp"
    local associated_phrase_source="${source_root}/ModulePackages/OVIMMandarin/OVAFAssociatedPhrase.cpp"
    local bopomofo_correction_source="${source_root}/ModulePackages/OVAFBopomofoCorrection/OVAFBopomofoCorrection.cpp"
    local full_width_source="${source_root}/ModulePackages/OVOFFullWidthCharacter/OVOFFullWidthCharacter.h"
    local han_convert_source="${source_root}/ModulePackages/OVOFHanConvert/OVOFHanConvert.h"
    local preference_app_dir="${source_root}/PreferenceApplications/OSX"
    local takao_preference_source="${preference_app_dir}/TakaoPreference.m"
    local takao_preference_toolbar_source="${preference_app_dir}/TakaoPreference_Toolbar.m"
    local takao_global_source="${source_root}/PreferenceApplications/OSX/TakaoGlobal.m"
    local minotaur_source="${source_root}/Frameworks/Minotaur/Source/Minotaur.cpp"
    local evalgelion_header="${source_root}/ModulePackages/OVAFEval/Evalgelion.h"
    local native_bopomofo_extconf="${source_root}/Frameworks/Formosa/Ruby/native_bopomofo/extconf.rb"
    local native_bopomofo_source="${source_root}/Frameworks/Formosa/Ruby/native_bopomofo/native_bopomofo.cpp"
    local project_file="${source_root}/Takao.xcodeproj/project.pbxproj"
    local database_cooker_makefile="${source_root}/Distributions/Takao/DatabaseCooker/Makefile"
    local one_key_source_dir="${source_root}/ModulePackages/YKAFOneKey"
    local ovaf_search_source_dir="${source_root}/ModulePackages/OVAFSearch"
    local static_pack_source_dir="${source_root}/ModulePackages/StaticPack"
    local one_key_online_data="${source_root}/Distributions/Takao/OnlineData/OneKey.plist"
    local sqlite_dir="${source_root}/ExternalLibraries/sqlite"
    local cerod_sqlite_dir="${source_root}/ExternalLibraries/sqlite-cerod-see"
    local cerod_sqlite_source="${cerod_sqlite_dir}/sqlite3-cerod-see-aes128-ccm-combined.c"
    local cooked_database_dir="${source_root}/Distributions/Takao/CookedDatabase"
    local cooked_keykey_database="${cooked_database_dir}/KeyKey.db"
    local dotmac_framework="${source_root}/ExternalLibraries/DotMacKit.framework"
    local dotmac_header="${dotmac_framework}/Headers/DotMacKit.h"
    local dotmac_binary="${dotmac_framework}/DotMacKit"
    local xib_count=0

    if [[ -f "${file_helper}" ]] && ! grep -q '#include <unistd.h>' "${file_helper}"; then
        ruby -0pi -e 'sub("#if defined(__APPLE__)\n    #include <dirent.h>\n    #include <stdio.h>\n", "#if defined(__APPLE__)\n    #include <dirent.h>\n    #include <stdio.h>\n    #include <unistd.h>\n")' "${file_helper}"
        source_patch_applied "openvanilla-file-helper-unistd" "OpenVanilla OVFileHelper.h now includes unistd.h."
    fi

    if [[ -f "${module_system}" ]] \
        && ruby -e 'content = File.read(ARGV[0]); exit(content[/PVPlistValue\* configDictionaryForModule.*?return false/m] ? 0 : 1)' "${module_system}"; then
        ruby -i -pe '
            if /^\s*virtual PVPlistValue\* configDictionaryForModule/
                $in_config_dictionary = true
            end

            if $in_config_dictionary && /^(\s*)return false;/
                $_ = "#{$1}return 0;\n"
            end

            if $in_config_dictionary && /^\s*}\s*$/
                $in_config_dictionary = false
            end
        ' "${module_system}"
        source_patch_applied "plainvanilla-config-null" "PlainVanilla configDictionaryForModule returns a null pointer."
    fi

    if [[ -f "${property_list}" ]] && grep -q 'PVPlistValue stringValue(string(' "${property_list}"; then
        ruby -pi -e '
            gsub("PVPlistValue stringValue(string([value UTF8String]));", "PVPlistValue stringValue((string([value UTF8String])));")
            gsub("PVPlistValue stringValue(string([[value stringValue] UTF8String]));", "PVPlistValue stringValue((string([[value stringValue] UTF8String])));")
        ' "${property_list}"
        source_patch_applied "plainvanilla-property-list-init" "PlainVanilla PVPropertyList string values use explicit initialization."
    fi

    if [[ -f "${nsstring_extension}" ]] && grep -q 'NSRange r = (NSRange){0, i + 1};' "${nsstring_extension}"; then
        ruby -pi -e 'gsub("NSRange r = (NSRange){0, i + 1};", "NSRange r = (NSRange){0, (NSUInteger)(i + 1)};")' "${nsstring_extension}"
        source_patch_applied "imk-nsstring-nsrange" "NSStringExtension uses NSUInteger for NSRange length."
    fi

    if [[ -f "${dictionary_window_source}" ]] && ! grep -q 'LFCrossDevelopmentTools.h' "${dictionary_window_source}"; then
        ruby -0pi -e 'sub(%Q{#import "CVDictionaryWindow.h"\n}, %Q{#import "CVDictionaryWindow.h"\n#import <LFExtensions/LFCrossDevelopmentTools.h>\n})' "${dictionary_window_source}"
        source_patch_applied "imk-dictionary-window-version-helpers" "CVDictionaryWindow declares OS version helpers."
    fi

    if [[ -f "${vertical_candidate_header}" ]] \
        && grep -q '@interface CVVerticalCandidateController : NSWindowController$' "${vertical_candidate_header}"; then
        ruby -pi -e 'sub("@interface CVVerticalCandidateController : NSWindowController\n", "@interface CVVerticalCandidateController : NSWindowController <NSTableViewDelegate, NSTableViewDataSource>\n")' "${vertical_candidate_header}"
        source_patch_applied "imk-vertical-candidate-protocols" "CVVerticalCandidateController declares table view protocols."
    fi

    if [[ -f "${symbol_controller_header}" ]] \
        && grep -q '@interface CVSymbolController : NSWindowController$' "${symbol_controller_header}"; then
        ruby -pi -e 'sub("@interface CVSymbolController : NSWindowController\n", "@interface CVSymbolController : NSWindowController <NSWindowDelegate>\n")' "${symbol_controller_header}"
        source_patch_applied "imk-symbol-controller-delegate" "CVSymbolController declares window delegate protocol."
    fi

    if [[ -f "${dictionary_controller_header}" ]] \
        && grep -q '@interface CVDictionaryController : NSWindowController$' "${dictionary_controller_header}"; then
        ruby -pi -e 'sub("@interface CVDictionaryController : NSWindowController\n", "@interface CVDictionaryController : NSWindowController <NSWindowDelegate, NSToolbarDelegate, WKUIDelegate, WebUIDelegate, WebFrameLoadDelegate, WebPolicyDelegate>\n")' "${dictionary_controller_header}"
        source_patch_applied "imk-dictionary-controller-delegates" "CVDictionaryController declares window, toolbar, and WebKit delegate protocols."
    fi

    if [[ -f "${open_vanilla_loader_source}" ]] && grep -q 'OVWildcard exp(string(\[pattern UTF8String\]));' "${open_vanilla_loader_source}"; then
        ruby -pi -e 'gsub("OVWildcard exp(string([pattern UTF8String]));", "OVWildcard exp((string([pattern UTF8String])));")' "${open_vanilla_loader_source}"
        source_patch_applied "loader-wildcard-init" "OpenVanillaLoader wildcard pattern uses explicit initialization."
    fi

    if [[ -f "${open_vanilla_loader_source}" ]] && grep -q '_loader->setPrimaryInputMethod("SmartMandarin");' "${open_vanilla_loader_source}"; then
        ruby -pi -e 'gsub(%q{_loader->setPrimaryInputMethod("SmartMandarin");}, %q{_loader->setPrimaryInputMethod("Generic-cj-cin");})' "${open_vanilla_loader_source}"
        source_patch_applied "loader-default-cangjie" "OpenVanillaLoader defaults to Cangjie for CangjieX source builds."
    fi

    if [[ -f "${open_vanilla_loader_source}" ]] \
        && ! grep -q 'OVSQLiteConnection\* dbc = 0;' "${open_vanilla_loader_source}"; then
        ruby -0pi -e '
            sub(%r{(    // NSLog\(@"db file = %s", dbFile\.c_str\(\)\);\n    \n)    #ifndef OVLOADER_USE_SQLITE_CRYPTO\n        _SQLiteDatabaseService = OVSQLiteDatabaseService::Create\(dbFile\);\n}, "\\1    OVSQLiteConnection* dbc = 0;\n\n    #ifndef OVLOADER_USE_SQLITE_CRYPTO\n        _SQLiteDatabaseService = OVSQLiteDatabaseService::Create(dbFile);\n        if (_SQLiteDatabaseService) {\n            _SQLiteDatabaseService->connection()->execute(\"PRAGMA synchronous = OFF\");\n            mainDBVersion = FetchDatabaseVersionInfo(_SQLiteDatabaseService->connection(), \"cooked_information\");\n        }\n")
            gsub("OVSQLiteConnection* dbc = OVSQLiteConnection::Open(dbFile);", "dbc = OVSQLiteConnection::Open(dbFile);")
        ' "${open_vanilla_loader_source}"
        source_patch_applied "loader-public-sqlite-metadata" "OpenVanillaLoader initializes SQLite metadata without the legacy crypto path."
    fi

    if [[ -f "${send_key_source}" ]] && grep -q 'GetScriptVariable(smCurrentScript, smScriptKeys)' "${send_key_source}"; then
        ruby -0pi -e 'sub(%r{#ifdef __x86_64__\n\t// always set to 0\n\tkeytable\.kchrID = 0;\n#else\n    keytable\.kchrID = \(short\) GetScriptVariable\(smCurrentScript, smScriptKeys\);\n#endif}, %Q{keytable.kchrID = 0;})' "${send_key_source}"
        source_patch_applied "imk-sendkey-no-carbon-script" "CVSendKey avoids removed Carbon script keyboard APIs."
    fi

    if [[ -f "${source_root}/Loaders/OSX-IMK/OpenVanillaController.mm" ]] \
        && ! grep -Fq 'inputText:(NSString*)string key:(NSInteger)keyCode' "${source_root}/Loaders/OSX-IMK/OpenVanillaController.mm"; then
        ruby - "${source_root}/Loaders/OSX-IMK/OpenVanillaController.mm" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)

source.gsub!("- (unsigned int)recognizedEvents:(id)sender", "- (NSUInteger)recognizedEvents:(id)sender")

fallbacks = <<'OBJC'
- (BOOL)inputText:(NSString*)string key:(NSInteger)keyCode modifiers:(NSUInteger)flags client:(id)sender
{
    NSEvent *event = [NSEvent keyEventWithType:NSKeyDown
                                      location:NSZeroPoint
                                 modifierFlags:flags
                                     timestamp:0
                                  windowNumber:0
                                       context:nil
                                    characters:string
                   charactersIgnoringModifiers:string
                                     isARepeat:NO
                                       keyCode:(unsigned short)keyCode];
    return [self handleEvent:event client:sender];
}

- (BOOL)inputText:(NSString*)string client:(id)sender
{
    NSEvent *event = [NSEvent keyEventWithType:NSKeyDown
                                      location:NSZeroPoint
                                 modifierFlags:0
                                     timestamp:0
                                  windowNumber:0
                                       context:nil
                                    characters:string
                   charactersIgnoringModifiers:string
                                     isARepeat:NO
                                       keyCode:0];
    return [self handleEvent:event client:sender];
}

- (BOOL)handleEvent:(NSEvent*)event client:(id)sender
OBJC

unless source.sub!(/\n- \(BOOL\)handleEvent:\(NSEvent\*\)event client:\(id\)sender\n\{/, "\n#{fallbacks}\n{")
  abort "OpenVanillaController handleEvent entry point was not found"
end

File.write(path, source)
RUBY
        source_patch_applied "imk-controller-inputtext-fallbacks" "OpenVanillaController exposes modern IMK inputText fallbacks."
    fi

    for loader_user_persistence_source in "${loader_user_persistence_mm}" "${loader_user_persistence_cpp}"; do
        if [[ -f "${loader_user_persistence_source}" ]] && ! grep -q 'extern "C" int sqlite3_key(sqlite3 \\*db' "${loader_user_persistence_source}"; then
            ruby -pi -e 'sub("int sqlite3_rekey(sqlite3 *db, const void *pKey, int nKey);", "extern \"C\" int sqlite3_key(sqlite3 *db, const void *pKey, int nKey);\nextern \"C\" int sqlite3_rekey(sqlite3 *db, const void *pKey, int nKey);")' "${loader_user_persistence_source}"
            if [[ "${loader_user_persistence_source}" == *".mm" ]]; then
                source_patch_applied "user-persistence-mm-sqlite-key" "$(basename "${loader_user_persistence_source}") declares sqlite3_key."
            else
                source_patch_applied "user-persistence-cpp-sqlite-key" "$(basename "${loader_user_persistence_source}") declares sqlite3_key."
            fi
        fi

        if [[ -f "${loader_user_persistence_source}" ]] \
            && ! grep -q 'Probe builds use an unencrypted user database' "${loader_user_persistence_source}"; then
            ruby -0pi -e '
                sub(%r{(    if \(m_userDatabase\) \{\n)(        pair<char\*, size_t> cle = ObtenirUserDonneCle\(\);\n        if \(cle\.first\) \{\n            sqlite3_key\(m_userDatabase->connection\(\), cle\.first, \(int\)cle\.second\);\n            free\(cle\.first\);\n        \}\n)(    \}\n)}, "\\1#ifdef OVLOADER_USE_SQLITE_CRYPTO\n\\2#else\n        // Probe builds use an unencrypted user database.\n#endif\n\\3")
            ' "${loader_user_persistence_source}"
            if [[ "${loader_user_persistence_source}" == *".mm" ]]; then
                source_patch_applied "user-persistence-mm-public-db" "$(basename "${loader_user_persistence_source}") skips user database crypto in public SQLite probe builds."
            else
                source_patch_applied "user-persistence-cpp-public-db" "$(basename "${loader_user_persistence_source}") skips user database crypto in public SQLite probe builds."
            fi
        fi
    done

    if [[ -f "${bpmf_user_phrase_helper}" ]] && ! grep -q 'extern "C" int sqlite3_key(sqlite3 \\*db' "${bpmf_user_phrase_helper}"; then
        ruby -pi -e 'sub("int sqlite3_rekey(sqlite3 *db, const void *pKey, int nKey);", "extern \"C\" int sqlite3_key(sqlite3 *db, const void *pKey, int nKey);\nextern \"C\" int sqlite3_rekey(sqlite3 *db, const void *pKey, int nKey);")' "${bpmf_user_phrase_helper}"
        source_patch_applied "manjusri-sqlite-key" "Manjusri declares sqlite3_key."
    fi

    if [[ -f "${smart_mandarin_source}" ]] && ! grep -q 'extern "C" int sqlite3_key(sqlite3 \\*db' "${smart_mandarin_source}"; then
        ruby -pi -e 'sub("int sqlite3_rekey(sqlite3 *db, const void *pKey, int nKey);", "extern \"C\" int sqlite3_key(sqlite3 *db, const void *pKey, int nKey);\nextern \"C\" int sqlite3_rekey(sqlite3 *db, const void *pKey, int nKey);")' "${smart_mandarin_source}"
        source_patch_applied "smart-mandarin-sqlite-key" "SmartMandarin declares sqlite3_key."
    fi

    if [[ -f "${evalgelion_header}" ]] \
        && ruby -e 'content = File.read(ARGV[0]); exit(content[/Node\* entity\(\).*?return false;\n\s*}\n\s*Node\* expression/m] ? 0 : 1)' "${evalgelion_header}"; then
        ruby -0pi -e 'sub(/(Node\* entity\(\).*?)return false;(\n\s*}\n\s*Node\* expression)/m, "\\1return 0;\\2")' "${evalgelion_header}"
        source_patch_applied "ovaf-eval-null-entity" "OVAFEval entity returns a null pointer."
    fi

    if [[ -f "${native_bopomofo_extconf}" ]] && grep -q "CONFIG\\['CXXFLAGS'\\]" "${native_bopomofo_extconf}"; then
        ruby -pi -e '
            if $_ =~ /CONFIG\[\047CXXFLAGS\047\].*DMANDARIN_USE_MINIMAL_OPENVANILLA/
                $_ = "$CXXFLAGS += \" -DMANDARIN_USE_MINIMAL_OPENVANILLA -I../../Headers -I../../../OpenVanilla/Headers\"\n"
            end
        ' "${native_bopomofo_extconf}"
        source_patch_applied "native-bopomofo-include-paths" "native_bopomofo passes Formosa include paths to modern Ruby mkmf."
    fi

    if [[ -f "${native_bopomofo_source}" ]] && grep -q 'RSTRING(rStr)->' "${native_bopomofo_source}"; then
        ruby -pi -e '
            gsub("RSTRING(rStr)->len", "RSTRING_LEN(rStr)")
            gsub("RSTRING(rStr)->ptr", "RSTRING_PTR(rStr)")
        ' "${native_bopomofo_source}"
        source_patch_applied "native-bopomofo-ruby-string-api" "native_bopomofo uses modern Ruby string accessors."
    fi

    if [[ -f "${minotaur_source}" ]] && grep -q '#include <openssl/rsa.h>' "${minotaur_source}"; then
        ruby -e 'File.write(ARGV[0], <<~SOURCE)
            /*
            Copyright (c) 2012, Yahoo! Inc.  All rights reserved.
            Copyrights licensed under the New BSD License. See the accompanying LICENSE
            file for terms.
            */

            #include <CommonCrypto/CommonDigest.h>
            #include <cstdlib>
            #include <cstring>
            #include "Minotaur.h"

            namespace Minotaur {

            size_t Minos::DigestSize()
            {
                return CC_SHA1_DIGEST_LENGTH;
            }

            char* Minos::Digest(const char* block, size_t blockSize)
            {
                char* digest = (char*)calloc(1, DigestSize());
                if (digest) {
                    CC_SHA1((const void*)block, (CC_LONG)blockSize, (unsigned char*)digest);
                }

                return digest;
            }

            pair<char*, size_t> Minos::Encrypt(const char* dataBlock, size_t blockSize, const char* RSAKey, size_t keySize, bool encryptWithPrivateKey)
            {
                return pair<char*, size_t>(0, 0);
            }

            pair<char*, size_t> Minos::Encrypt(const pair<char*, size_t>& block, const pair<char*, size_t>& key, bool encryptWithPrivateKey)
            {
                return Encrypt(block.first, block.second, key.first, key.second, encryptWithPrivateKey);
            }

            pair<char*, size_t> Minos::GetBack(const pair<char*, size_t>& block, const pair<char*, size_t>& key, bool decryptWithPublicKey)
            {
                return GetBack(block.first, block.second, key.first, key.second, decryptWithPublicKey);
            }

            pair<char*, size_t> Minos::GetBack(const char* encodedBlock, size_t blockSize, const char* RSAKey, size_t keySize, bool decryptWithPublicKey)
            {
                return pair<char*, size_t>(0, 0);
            }

            bool Minos::LazyMatch(const char* b1, const char* b2, size_t size)
            {
                for (size_t i = 0 ; i < size ; ++i) {
                    if (b1[i] != b2[i]) {
                        return false;
                    }
                }

                return true;
            }

            bool Minos::ValidateFile(const string& filename, const pair<char*, size_t>& block, const pair<char*, size_t>& key)
            {
                return ValidateFile(filename, block.first, block.second, key.first, key.second);
            }

            bool Minos::ValidateFile(const string& filename, const char* encodedBlock, size_t blockSize, const char* RSAKey, size_t keySize)
            {
                return false;
            }

            pair<char*, size_t> Minos::BinaryFromHexString(const string& str)
            {
                pair<char*, size_t> result(0, 0);
                if (str.size() % 2) {
                    return result;
                }

                if (!str.size()) {
                    return result;
                }

                result.second = str.size() / 2;
                result.first = (char*)calloc(1, result.second);

                const char* map1 = "0123456789abcdef";
                const char* map2 = "0123456789ABCDEF";

                size_t s = str.size();
                for (size_t i = 0 ; i < s ; i += 2) {
                    const char* p;
                    unsigned char hi = 0;
                    unsigned char lo = 0;

                    p = strchr(map1, str[i]);
                    if (p) {
                        hi = (unsigned char)(p - map1);
                    }
                    else {
                        p = strchr(map2, str[i]);
                        if (p) {
                            hi = (unsigned char)(p - map2);
                        }
                    }

                    p = strchr(map1, str[i + 1]);
                    if (p) {
                        lo = (unsigned char)(p - map1);
                    }
                    else {
                        p = strchr(map2, str[i + 1]);
                        if (p) {
                            lo = (unsigned char)(p - map2);
                        }
                    }

                    result.first[i / 2] = (hi << 4) | lo;
                }

                return result;
            }

            };
        SOURCE
        ' "${minotaur_source}"
        source_patch_applied "minotaur-commoncrypto-digest" "Minotaur uses CommonCrypto SHA1 and disables obsolete OpenSSL RSA probe paths."
    fi

    if [[ -f "${project_file}" ]] && grep -q 'libcrypto.dylib in Frameworks' "${project_file}"; then
        ruby -ni -e 'print unless /\/\* libcrypto\.dylib in Frameworks \*\//' "${project_file}"
        source_patch_applied "project-remove-libcrypto-link" "removed obsolete libcrypto.dylib link entries."
    fi

    if [[ -f "${project_file}" ]] && grep -q 'OVLOADER_USE_SQLITE_CRYPTO' "${project_file}"; then
        ruby -ni -e 'print unless /^\s*OVLOADER_USE_SQLITE_CRYPTO,\s*$/' "${project_file}"
        source_patch_applied "project-public-sqlite-loader" "IMK loader uses the public SQLite database path for probe builds."
    fi

    if [[ -f "${project_file}" ]] && grep -q 'YahooKeyKey_1_Connection' "${project_file}"; then
        ruby - "${project_file}" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)

{
  "YahooKeyKeyServiceTiger" => "CangjieXServiceTiger",
  "YahooKeyKeyService" => "CangjieXService",
  "YahooKeyKey_1_ConnectionTiger" => "CangjieX_1_ConnectionTiger",
  "YahooKeyKey_1_Connection" => "CangjieX_1_Connection",
  "PVLOADERPOLICY_LOADER_IDENTIFIER=\\\"com.yahoo.KeyKey\\\"" => "PVLOADERPOLICY_LOADER_IDENTIFIER=\\\"io.github.geekstek.inputmethod.CangjieX\\\"",
  "PVLOADERPOLICY_LOADER_NAME=\\\"Yahoo!\\ KeyKey\\\"" => "PVLOADERPOLICY_LOADER_NAME=\\\"CangjieX\\\"",
}.each do |old_value, new_value|
  source.gsub!(old_value, new_value)
end

if source.include?("YahooKeyKey_1_Connection")
  abort "project still contains YahooKeyKey_1_Connection after CangjieX replacement"
end

File.write(path, source)
RUBY
        source_patch_applied "project-cangjiex-identifiers" "source-built loader uses CangjieX service and preference identifiers."
    fi

    local onekey_patch_applied=0

    if [[ -f "${open_vanilla_loader_source}" ]] && grep -q 'YKAFOneKeyPackage' "${open_vanilla_loader_source}"; then
        ruby - "${open_vanilla_loader_source}" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)

source.gsub!(%Q{#import "YKAFOneKeyPackage.h"\n}, "")
source.gsub!(%r{virtual void\* loaderSpecificDataObjectForName\(const string& name\)\n\t\{.*?\n\t\}}m, "virtual void* loaderSpecificDataObjectForName(const string& name)\n\t{\n\t\t(void)name;\n\t\treturn 0;\n\t}")
source.gsub!(%r{\n\t\t_oneKeyDataHTTPRequest = \[LFHTTPRequest new\];\n\t\t\[_oneKeyDataHTTPRequest setDelegate:self\];\n}m, "\n")
source.gsub!(/\n\t\t_mergedOneKeyData = new PVPlistValue\(PVPlistValue::Dictionary\);\n/, "\n")
source.gsub!(/\n\t\t_userOneKeyPlist = 0;\n/, "\n")
source.gsub!(/\n\t\[_oneKeyDataHTTPRequest release\];\n/, "\n")
source.gsub!(/\n\tdelete _mergedOneKeyData;\n/, "\n")
source.gsub!(%r{\n\tif \(_userOneKeyPlist\) \{\n\t\tdelete _userOneKeyPlist;\n\t\}\n}m, "\n")
source.gsub!(%r{\n\tif \(!_userOneKeyPlist\) \{\n\t\t_userOneKeyPlist = new PVPropertyList\(OVPathHelper::PathCat\(userDataPath, "UserOneKey.plist"\)\);\n\t\}\n}m, "\n")
source.gsub!(%r{\n[ \t]*pkg = new YKAFOneKeyPackage;\n[ \t]*pkg->initialize\(&pathInfo, _loaderService\);\n[ \t]*_staticModuleLoadingSystem->addInitializedPackage\("YKAFOneKeyPackage", pkg\);\s*}, "\n")
source.gsub!(%r{\n- \(void\)_handleOneKeyTimer:\(NSTimer \*\)timer\n\{.*?\n\}\n\n- \(void\)_handleCannedMessagesTimer}m, "\n- (void)_handleCannedMessagesTimer")
source.gsub!(%r{\n\telse if \(request == _oneKeyDataHTTPRequest\) \{.*?\n\t\}\n\telse if \(request == _cannedMessagesDataHTTPRequest\)}m, "\n\telse if (request == _cannedMessagesDataHTTPRequest)")
source.gsub!(%r{\n\telse if \(request == _oneKeyDataHTTPRequest\) \{\n\t\t\[NSTimer scheduledTimerWithTimeInterval:OVLOADER_HTTP_FAIL_RETRY_TIMEINTERVAL target:self selector:@selector\(_handleOneKeyTimer:\) userInfo:nil repeats:NO\];\n\t\}}, "")
source.gsub!(%r{\n\t\[NSTimer scheduledTimerWithTimeInterval:OVLOADER_HTTP_FIRST_FETCH_DELAY target:self selector:@selector\(_handleOneKeyTimer:\) userInfo:nil repeats:NO\];\n}m, "\n")
source.gsub!(%r{\n- \(void\)mergeOneKeyData\n\{.*?\n\}\n\n- \(PVPlistValue \*\)mergedOneKeyData\n\{.*?\n\}\n\n- \(void\)syncUserOneKeyData\n\{.*?\n\}\n\n}m, "\n")
source.gsub!(/\n\t\[self mergeOneKeyData\];\n/, "\n")

if source.include?("YKAFOneKeyPackage") ||
   source.include?("_handleOneKeyTimer") ||
   source.include?("onekey_services") ||
   source.include?("mergeOneKeyData") ||
   source.include?("OneKeyDataCopy") ||
   source.include?("UserOneKey") ||
   source.include?("_oneKeyDataHTTPRequest") ||
   source.include?("_mergedOneKeyData") ||
   source.include?("_userOneKeyPlist")
  abort "OpenVanillaLoader still contains OneKey service code"
end

File.write(path, source)
RUBY
        onekey_patch_applied=1
    fi

    if [[ -f "${open_vanilla_loader_header}" ]] && grep -q 'OneKey' "${open_vanilla_loader_header}"; then
        ruby -ni -e 'print unless /oneKeyDataHTTPRequest|_mergedOneKeyData|user onekey support|_userOneKeyPlist|mergeOneKeyData|mergedOneKeyData|syncUserOneKeyData/' "${open_vanilla_loader_header}"
        onekey_patch_applied=1
    fi

    if [[ -f "${open_vanilla_config_header}" ]] && grep -q 'TAKAO_ONEKEY_URL' "${open_vanilla_config_header}"; then
        ruby -0pi -e 'gsub(%r{\n#ifndef TAKAO_ONEKEY_URL\n.*?\n#endif\n}m, "\n")' "${open_vanilla_config_header}"
        onekey_patch_applied=1
    fi

    if [[ -f "${open_vanilla_main_source}" ]] && grep -q 'OneKey.plist' "${open_vanilla_main_source}"; then
        ruby -0pi -e 'gsub(%r{\n\t// migrates Search\.plist -> OneKey\.plist\n.*?\n\t\}\n\t\n}m, "\n")' "${open_vanilla_main_source}"
        onekey_patch_applied=1
    fi

    if [[ -f "${open_vanilla_controller_source}" ]] && grep -q 'onekeyAction' "${open_vanilla_controller_source}"; then
        ruby - "${open_vanilla_controller_source}" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)

source.gsub!('if (identifier == "OneKey" || identifier == "Evaluator")', 'if (identifier == "Evaluator")')
source.gsub!(/\n\t\[\[OpenVanillaLoader sharedInstance\] syncUserOneKeyData\];\n/, "\n")
source.gsub!(%r{\n\tNSMenuItem \*onekeyMenuItem = \[\[\[NSMenuItem alloc\] init\] autorelease\];\n\t\[onekeyMenuItem setTarget:self\];\n\t\[onekeyMenuItem setAction:@selector\(onekeyAction:\)\];\n\t\[onekeyMenuItem setTitle:LFLSTR\(@"One-Key"\)\];\n\t\[menu addItem:onekeyMenuItem\];\n}m, "\n")
source.gsub!(%r{\n- \(void\)onekeyAction:\(id\)sender\n\{.*?\n\}\n- \(void\)symbolAction}m, "\n- (void)symbolAction")

if source.include?("onekeyAction") ||
   source.include?("syncUserOneKeyData") ||
   source.include?("One-Key") ||
   source.include?('"OneKey"')
  abort "OpenVanillaController still contains OneKey UI code"
end

File.write(path, source)
RUBY
        onekey_patch_applied=1
    fi

    if [[ -f "${database_cooker_makefile}" ]] && grep -q 'ONEKEY_SERVICE_KEY' "${database_cooker_makefile}"; then
        ruby -ni -e 'print unless /ONEKEY_|OneKey\.plist|\$\(INSERTER\) \$\(DB\) \$\(PREPOPULATE_TABLE_NAME\) \$\(ONEKEY_SERVICE_KEY\)/' "${database_cooker_makefile}"
        onekey_patch_applied=1
    fi

    if [[ -f "${project_file}" ]] && grep -q 'YKAFOneKey' "${project_file}"; then
        ruby -ni -e 'print unless /YKAFOneKey/' "${project_file}"
        onekey_patch_applied=1
    fi

    if [[ -d "${one_key_source_dir}" ]]; then
        rm -rf "${one_key_source_dir}"
        onekey_patch_applied=1
    fi

    if [[ -d "${ovaf_search_source_dir}" ]]; then
        rm -rf "${ovaf_search_source_dir}"
        onekey_patch_applied=1
    fi

    if [[ -d "${static_pack_source_dir}" ]]; then
        rm -rf "${static_pack_source_dir}"
        onekey_patch_applied=1
    fi

    if [[ -f "${one_key_online_data}" ]]; then
        rm -f "${one_key_online_data}"
        onekey_patch_applied=1
    fi

    if ((onekey_patch_applied)); then
        source_patch_applied "remove-onekey-service" "removed the legacy backtick-triggered Yahoo OneKey service menu, module registration, and preloaded data."
    fi

    local input_menu_patch_applied=0

    if [[ -f "${open_vanilla_controller_source}" ]] \
        && { grep -q 'helpMenuItem\|Bopomofo Correction\|Associated Phrase\|com.yahoo.inputmethod.KeyKey.Preferences\|openFile:preferencePath' "${open_vanilla_controller_source}" \
            || ! grep -q 'identifier == "Evaluator" || identifier == "OVAFAssociatedPhrase"' "${open_vanilla_controller_source}"; }; then
        PROJECT_URL="${PROJECT_URL}" PREFERENCES_BUNDLE_ID="${PREFERENCES_BUNDLE_ID}" ruby - "${open_vanilla_controller_source}" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)
original = source.dup
preferences_bundle_id = ENV.fetch("PREFERENCES_BUNDLE_ID")

unless source.include?('isAroundFilterActivated("OVAFAssociatedPhrase")')
  unless source.sub!(%Q{    [OpenVanillaLoader sharedLoader]->syncLoaderConfig();\n\tOVKeyValueMap kvm = [OpenVanillaLoader sharedLoader]->configKeyValueMap();\n}, %Q{    [OpenVanillaLoader sharedLoader]->syncLoaderConfig();\n    if (![OpenVanillaLoader sharedLoader]->isAroundFilterActivated("OVAFAssociatedPhrase")) {\n        [OpenVanillaLoader sharedLoader]->toggleAroundFilter("OVAFAssociatedPhrase");\n    }\n\tOVKeyValueMap kvm = [OpenVanillaLoader sharedLoader]->configKeyValueMap();\n})
    abort "OpenVanillaController activateServer syncLoaderConfig block was not found"
  end
end

source.gsub!('if (identifier == "Evaluator") {', 'if (identifier == "Evaluator" || identifier == "OVAFAssociatedPhrase") {')
source.gsub!(%r{\n- \(void\)helpAction:\(id\)sender\n\{.*?\n\}\n\n- \(void\)preferenceAction}m, "\n- (void)preferenceAction")
source.gsub!(%r{\n\tNSMenuItem \*helpMenuItem = \[\[\[NSMenuItem alloc\] init\] autorelease\];\n\t\[helpMenuItem setTarget:self\];\n\t\[helpMenuItem setAction:@selector\(helpAction:\)\];\n\t\[helpMenuItem setTitle:LFLSTR\(@"Help"\)\];\n\t\[menu addItem:helpMenuItem\];\n[ \t]*}m, "\n")
source.gsub!(%r{\n\tif \(!\[\[NSWorkspace sharedWorkspace\] openFile:preferencePath\]\) \{\n\t\t\[\[NSWorkspace sharedWorkspace\] launchAppWithBundleIdentifier:@"com\.yahoo\.inputmethod\.KeyKey\.Preferences" options:NSWorkspaceLaunchDefault additionalEventParamDescriptor:nil launchIdentifier:nil\];\n\t\}\n}m, %Q{\n\tNSURL *preferenceURL = [NSURL fileURLWithPath:preferencePath];\n\tif (![[NSWorkspace sharedWorkspace] openURL:preferenceURL]) {\n\t\t[[NSWorkspace sharedWorkspace] launchAppWithBundleIdentifier:@"#{preferences_bundle_id}" options:NSWorkspaceLaunchDefault additionalEventParamDescriptor:nil launchIdentifier:nil];\n\t}\n})

if source.include?("helpAction:") ||
   source.include?("helpMenuItem") ||
   source.include?('LFLSTR(@"Help")') ||
   source.include?("http://tw.media.yahoo.com/keykey/help/") ||
   source.include?("com.yahoo.inputmethod.KeyKey.Preferences") ||
   source.include?("openFile:preferencePath")
  abort "OpenVanillaController still contains legacy help menu code"
end

unless source.include?(preferences_bundle_id) && source.include?("[NSWorkspace sharedWorkspace] openURL:preferenceURL")
  abort "OpenVanillaController does not use the modern Preferences launch path"
end

unless source.include?('identifier == "Evaluator" || identifier == "OVAFAssociatedPhrase"')
  abort "OpenVanillaController does not hide and force-enable the associated phrase filter"
end

if source == original
  abort "OpenVanillaController menu modernization made no changes"
end

File.write(path, source)
RUBY
        input_menu_patch_applied=1
    fi

    if [[ -f "${about_controller_source}" ]] && grep -q 'tw.help.cc.yahoo.com/feedback.html' "${about_controller_source}"; then
        PROJECT_URL="${PROJECT_URL}" ruby - "${about_controller_source}" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)
project_url = ENV.fetch("PROJECT_URL")

source.gsub!(%q{@"http://tw.help.cc.yahoo.com/feedback.html?id=3430"}, %Q{@"#{project_url}"})

if source.include?("tw.help.cc.yahoo.com") || !source.include?(project_url)
  abort "CVAboutController still points to the legacy Yahoo feedback URL"
end

File.write(path, source)
RUBY
        input_menu_patch_applied=1
    fi

    if [[ -f "${bopomofo_correction_source}" ]] && grep -q 'Bopomofo Correction' "${bopomofo_correction_source}"; then
        ruby -pi -e 'gsub(%q{return string("Bopomofo Correction");}, %q{return tcname;})' "${bopomofo_correction_source}"
        input_menu_patch_applied=1
    fi

    if [[ -f "${full_width_source}" ]] && grep -q 'Use Full-Width Characters' "${full_width_source}"; then
        ruby -pi -e 'gsub(%q{return string("Use Full-Width Characters");}, %q{return tcname;})' "${full_width_source}"
        input_menu_patch_applied=1
    fi

    if [[ -f "${han_convert_source}" ]] && grep -q 'Traditional Chinese to Simpified Chinese\|Simplified Chinese to Traditional Chinese' "${han_convert_source}"; then
        ruby -pi -e '
            gsub(%q{return "Traditional Chinese to Simpified Chinese";}, %q{return "繁體轉簡體";})
            gsub(%q{return "Simplified Chinese to Traditional Chinese";}, %q{return "簡體轉繁體";})
        ' "${han_convert_source}"
        input_menu_patch_applied=1
    fi

    if [[ -f "${associated_phrase_source}" ]] && grep -q 'Associated Phrase' "${associated_phrase_source}"; then
        ruby -pi -e 'gsub(%q{return string("Associated Phrase");}, %q{return tcname;})' "${associated_phrase_source}"
        input_menu_patch_applied=1
    fi

    if ((input_menu_patch_applied)); then
        source_patch_applied "modernize-input-menu" "forced associated phrases on, removed the legacy help menu, localized menu fallbacks, and pointed About to GitHub."
    fi

    if [[ -f "${takao_global_source}" ]] && grep -q '\[fromColor hueComponent\]' "${takao_global_source}"; then
        ruby - "${takao_global_source}" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)

old_code_pattern = %r{#if MAC_OS_X_VERSION_MAX_ALLOWED > MAC_OS_X_VERSION_10_4\s*
\s*if \(\[aColor colorSpaceName\] == NSDeviceWhiteColorSpace \|\| \[aColor colorSpaceName\] ==NSCalibratedWhiteColorSpace\).*?toColor = \[NSColor colorWithCalibratedHue:hue saturation:saturation brightness:brightness alpha:1\.0\];\s*#endif\s*}m

new_code = <<'OBJC'
#if MAC_OS_X_VERSION_MAX_ALLOWED > MAC_OS_X_VERSION_10_4
	fromColor = [aColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
	if (!fromColor) {
		fromColor = [aColor colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
	}
	if (!fromColor) {
		fromColor = [NSColor colorWithCalibratedRed:1.0 green:1.0 blue:1.0 alpha:[aColor alphaComponent]];
	}

	CGFloat hue = 0.0;
	CGFloat saturation = 0.0;
	CGFloat brightness = 1.0;
	CGFloat alpha = 1.0;
	[fromColor getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];
	toColor = [NSColor colorWithCalibratedHue:hue saturation:saturation brightness:(brightness / 3.0) alpha:alpha];
#endif
OBJC

unless source.sub!(old_code_pattern, new_code)
  abort "TakaoGlobal color swatch block was not found"
end

if source.include?("[fromColor hueComponent]") ||
   source.include?("[fromColor saturationComponent]") ||
   source.include?("[fromColor brightnessComponent]")
  abort "TakaoGlobal still reads HSB components without RGB conversion"
end

File.write(path, source)
RUBY
        source_patch_applied "preferences-color-rgb" "converted preference color swatches to RGB before deriving hue and brightness."
    fi

    local preferences_ui_patch_applied=0

    if [[ -f "${takao_global_source}" ]] \
        && { grep -q 'Shortcut Key:\|ToggleInputMethodWithControlBackslash\|ModulesSuppressedFromUI\|Purple\|Default" forKey:@"HighlightColor' "${takao_global_source}" \
            || ! grep -q '_modernizeGeneralPane' "${takao_global_source}"; }; then
        ruby - "${takao_global_source}" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)
original = source.dup

source.gsub!('[_takaoDictionary setValue:@"Default" forKey:@"HighlightColor"];', '[_takaoDictionary setValue:@"0.000000 0.478431 0.749020" forKey:@"HighlightColor"];')
unless source.sub!(/\t\[_takaoDictionary setValue:@"true" forKey:@"ToggleInputMethodWithControlBackslash"\];\n\n\tLFRetainAssign/, "\t[_takaoDictionary setValue:[NSArray array] forKey:@\"ActivatedOutputFilters\"];\n\n\tLFRetainAssign")
  abort "TakaoGlobal output filter default block was not found"
end

old_toggle_ui = %r{#if \(MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5\)\s*
\s*if \(\[\[_takaoDictionary valueForKey:@"ToggleInputMethodWithControlBackslash"\] isEqualToString:@"true"\]\)
\s*\[_useCtrlBackSlashToggleInputMethod setIntValue:1\];
\s*else
\s*\[_useCtrlBackSlashToggleInputMethod setIntValue:0\];\s*
#else
\s*\[_useCtrlBackSlashToggleInputMethod setHidden:YES\];
//\s*\[_useCtrlBackSlashToggleInputMethod setEnabled:NO\];
//\s*NSString \*title = \[_useCtrlBackSlashToggleInputMethod title\];
//\s*\[_useCtrlBackSlashToggleInputMethod setTitle:\[NSString stringWithFormat:@"%@ \(10\.5 only\)", title\]\];
#endif[ \t]*\n}m

new_toggle_ui = <<'OBJC'
	NSArray *activatedOutputFilters = [_takaoDictionary valueForKey:@"ActivatedOutputFilters"];
	if ([activatedOutputFilters isKindOfClass:[NSArray class]] && [activatedOutputFilters containsObject:@"OVOFHanConvert-TC2SC"])
		[_useCtrlBackSlashToggleInputMethod setIntValue:1];
	else
		[_useCtrlBackSlashToggleInputMethod setIntValue:0];
OBJC

unless source.sub!(old_toggle_ui, new_toggle_ui)
  abort "TakaoGlobal output filter UI block was not found"
end

old_toggle_write = "\n\tif ([_useCtrlBackSlashToggleInputMethod intValue]) \n\t\t[_takaoDictionary setValue:@\"true\" forKey:@\"ToggleInputMethodWithControlBackslash\"];\n\telse\n\t\t[_takaoDictionary setValue:@\"false\" forKey:@\"ToggleInputMethodWithControlBackslash\"];\t\n"

new_toggle_write = <<'OBJC'

	NSArray *currentOutputFilters = [_takaoDictionary valueForKey:@"ActivatedOutputFilters"];
	if (![currentOutputFilters isKindOfClass:[NSArray class]])
		currentOutputFilters = [NSArray array];

	NSMutableArray *activatedOutputFilters = [NSMutableArray arrayWithArray:currentOutputFilters];
	[activatedOutputFilters removeObject:@"OVOFHanConvert-TC2SC"];
	if ([_useCtrlBackSlashToggleInputMethod intValue])
		[activatedOutputFilters addObject:@"OVOFHanConvert-TC2SC"];
	[_takaoDictionary setValue:activatedOutputFilters forKey:@"ActivatedOutputFilters"];
OBJC

unless source.sub!(old_toggle_write, new_toggle_write)
  abort "TakaoGlobal output filter write block was not found"
end

modern_helpers = <<'OBJC'
- (void)_setSubviewWithText:(NSString *)oldText toText:(NSString *)newText inView:(NSView *)view
{
	NSEnumerator *enumerator = [[view subviews] objectEnumerator];
	NSView *subview = nil;
	while (subview = [enumerator nextObject]) {
		if ([subview isKindOfClass:[NSButton class]] && [[(NSButton *)subview title] isEqualToString:oldText]) {
			[(NSButton *)subview setTitle:newText];
		}
		else if ([subview isKindOfClass:[NSTextField class]] && [[(NSTextField *)subview stringValue] isEqualToString:oldText]) {
			[(NSTextField *)subview setStringValue:newText];
		}
		[self _setSubviewWithText:oldText toText:newText inView:subview];
	}
}

- (void)_hideSubviewWithText:(NSString *)text inView:(NSView *)view
{
	NSEnumerator *enumerator = [[view subviews] objectEnumerator];
	NSView *subview = nil;
	while (subview = [enumerator nextObject]) {
		if ([subview isKindOfClass:[NSButton class]] && [[(NSButton *)subview title] isEqualToString:text]) {
			[subview setHidden:YES];
		}
		else if ([subview isKindOfClass:[NSTextField class]] && [[(NSTextField *)subview stringValue] isEqualToString:text]) {
			[subview setHidden:YES];
		}
		[self _hideSubviewWithText:text inView:subview];
	}
}

- (void)_hideOneKeyPopUpButtonsInView:(NSView *)view
{
	NSEnumerator *enumerator = [[view subviews] objectEnumerator];
	NSView *subview = nil;
	while (subview = [enumerator nextObject]) {
		if ([subview isKindOfClass:[NSPopUpButton class]]) {
			NSEnumerator *itemEnumerator = [[(NSPopUpButton *)subview itemArray] objectEnumerator];
			NSMenuItem *item = nil;
			while (item = [itemEnumerator nextObject]) {
				NSString *title = [item title];
				if ([title hasPrefix:@"Use`"] || [title hasPrefix:@"Use ~"]) {
					[subview setHidden:YES];
					break;
				}
			}
		}
		[self _hideOneKeyPopUpButtonsInView:subview];
	}
}

- (void)_modernizeGeneralPane
{
	NSView *view = [_soundCheckBox superview];
	if (!view)
		return;

	[view setFrame:NSMakeRect(0, 0, 480, 220)];

	[self _setSubviewWithText:@"Candidates:" toText:@"候選窗：" inView:view];
	[self _setSubviewWithText:@"候選字窗：" toText:@"候選窗：" inView:view];
	[self _setSubviewWithText:@"Highlight Color:" toText:@"標示顏色：" inView:view];
	[self _setSubviewWithText:@"標示顏色：" toText:@"標示顏色：" inView:view];
	[self _setSubviewWithText:@"Beep on Error:" toText:@"提示音：" inView:view];
	[self _setSubviewWithText:@"錯誤提示音：" toText:@"提示音：" inView:view];
	[self _setSubviewWithText:@"Enable alert sound" toText:@"輸入錯誤時播放提示音" inView:view];
	[self _setSubviewWithText:@"啟用警示音效" toText:@"輸入錯誤時播放提示音" inView:view];
	[self _setSubviewWithText:@"... with this audio clip:" toText:@"提示音效：" inView:view];
	[self _setSubviewWithText:@"… with this audio clip:" toText:@"提示音效：" inView:view];
	[self _setSubviewWithText:@"... 使用這個音效：" toText:@"提示音效：" inView:view];
	[self _setSubviewWithText:@"Vertical" toText:@"直式" inView:view];
	[self _setSubviewWithText:@"Horizontal" toText:@"橫式" inView:view];

	NSArray *hiddenTexts = [NSArray arrayWithObjects:
		@"Input Methods:",
		@"輸入法：",
		@"You can hide some Input Methods from the Input Menu.",
		@"您可以從輸入法選單隱藏部分輸入法。",
		@"Shortcut Key:",
		@"快速鍵：",
		@" to activate One-Key feature.",
		@"啟用一點通功能。",
		nil];
	NSEnumerator *hiddenEnumerator = [hiddenTexts objectEnumerator];
	NSString *hiddenText = nil;
	while (hiddenText = [hiddenEnumerator nextObject]) {
		[self _hideSubviewWithText:hiddenText inView:view];
	}

	[self _hideOneKeyPopUpButtonsInView:view];
	[[_moduleListTableView enclosingScrollView] setHidden:YES];
	[_keyboardLayoutPopUpButton setHidden:YES];
	[_useCtrlBackSlashToggleInputMethod setHidden:NO];
	[_useCtrlBackSlashToggleInputMethod setTitle:@"輸入繁體時輸出簡體"];

	[_candidateWindowStyleMatrix setFrame:NSMakeRect(132, 173, 236, 18)];
	[_highlightColorPopUpButton setFrame:NSMakeRect(129, 141, 242, 26)];
	[_useCtrlBackSlashToggleInputMethod setFrame:NSMakeRect(130, 118, 260, 18)];
	[_soundCheckBox setFrame:NSMakeRect(130, 73, 260, 18)];
	[_soundListPopUpButton setFrame:NSMakeRect(129, 19, 242, 26)];
	[_stopPlayiongButton setFrame:NSMakeRect(410, 19, 33, 25)];
}

OBJC

unless source.include?('_modernizeGeneralPane')
  unless source.sub!(/\n- \(void\)setUI\n\{/, "\n#{modern_helpers}- (void)setUI\n{")
    abort "TakaoGlobal setUI insertion point was not found"
  end
end

unless source.include?('[self _modernizeGeneralPane];')
  unless source.sub!(/\t\[_highlightColorPopUpButton setColorSelection:\[_takaoDictionary valueForKey:@"HighlightColor"\]\];\n\}/, "\t[_highlightColorPopUpButton setColorSelection:[_takaoDictionary valueForKey:@\"HighlightColor\"]];\n\t[self _modernizeGeneralPane];\n}")
    abort "TakaoGlobal setUI modernization call point was not found"
  end
end

source.gsub!(%q{NSMenuItem *purpleItem = [[[NSMenuItem alloc] initWithTitle:LFLSTR(@"Purple") action:nil keyEquivalent:@""] autorelease];
	[purpleItem setImage:[self imageForColor:[NSColor purpleColor]]];}, %q{NSMenuItem *purpleItem = [[[NSMenuItem alloc] initWithTitle:LFLSTR(@"Cangjie Blue") action:nil keyEquivalent:@""] autorelease];
	NSColor *cangjieBlueColor = [NSColor colorWithCalibratedRed:0.00 green:0.478431 blue:0.749020 alpha:1.00];
	[purpleItem setImage:[self imageForColor:cangjieBlueColor]];})
source.gsub!('[_colors addObject:@"Default"];', '[_colors addObject:@"0.000000 0.478431 0.749020"];')
source.gsub!('if ([_initString isEqualToString:@"Default"] || [_initString isEqualToString:@"Purple"]) {', 'if ([_initString isEqualToString:@"Default"] || [_initString isEqualToString:@"Purple"] || [_initString isEqualToString:@"Cangjie Blue"] || [_initString isEqualToString:@"0.000000 0.478431 0.749020"]) {')

if source.include?('ToggleInputMethodWithControlBackslash') ||
   source.include?('Use Ctrl + Backslash to toggle Input Methods.') ||
   source.include?('NSDeviceWhiteColorSpace || [aColor colorSpaceName] ==NSCalibratedWhiteColorSpace')
  abort "TakaoGlobal still contains legacy preference UI behavior"
end

if source == original
  abort "TakaoGlobal preference modernization made no changes"
end

File.write(path, source)
RUBY
        preferences_ui_patch_applied=1
    fi

    if [[ -f "${takao_preference_source}" ]] \
        && grep -q 'GeneralToolbarItemIdentifier\|_keyboardLayoutContentView addSubview\|setActiveView:_generalView' "${takao_preference_source}"; then
        ruby - "${takao_preference_source}" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)
original = source.dup

source.gsub!('[toolbar setSelectedItemIdentifier:GeneralToolbarItemIdentifier];', '[toolbar setSelectedItemIdentifier:CangjieToolbarItemIdentifier];')
source.gsub!(%r{#if \(MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_X_VERSION_10_5\).*?\[_keyboardLayoutContentView addSubview:_keyboardLayoutView\];\s*#endif}m, "\t[_keyboardLayoutContentView removeFromSuperview];\n\t[_generalView setFrame:NSMakeRect(0, 0, 480, 220)];")
source.gsub!('[self setActiveView:_generalView animate:NO];', '[self setActiveView:_cangjieView animate:NO];')
source.gsub!('[self setAppIcon:[NSImage imageNamed:@"general"]];', '[self setAppIcon:[NSImage imageNamed:@"cangjie"]];')
source.gsub!('[window setTitle:LFLSTR(GeneralToolbarItemIdentifier)];', '[window setTitle:LFLSTR(CangjieToolbarItemIdentifier)];')

if source.include?('[_keyboardLayoutContentView addSubview:_keyboardLayoutView]') ||
   source.include?('[toolbar setSelectedItemIdentifier:GeneralToolbarItemIdentifier];') ||
   source.include?('[self setActiveView:_generalView animate:NO];')
  abort "TakaoPreference still opens the legacy General pane"
end

if source == original
  abort "TakaoPreference modernization made no changes"
end

File.write(path, source)
RUBY
        preferences_ui_patch_applied=1
    fi

    if [[ -f "${takao_preference_toolbar_source}" ]] \
        && grep -q 'PhoneticToolbarItemIdentifier\|UpdateToolbarItemIdentifier\|PluginToolbarItemIdentifier\|GenericToolbarItemIdentifier' "${takao_preference_toolbar_source}"; then
        ruby - "${takao_preference_toolbar_source}" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)
original = source.dup

minimal_toolbar = <<'OBJC'
{
	return [NSArray arrayWithObjects:
		CangjieToolbarItemIdentifier,
		GeneralToolbarItemIdentifier,
		PhraseToolbarItemIdentifier,
		nil];
}
OBJC

source.sub!(%r{\{\n\tNSMutableArray \*array = \[NSMutableArray array\];.*?\n\treturn array;\n\n\}}m, minimal_toolbar)
source.gsub!(%r{\{\n\treturn \[NSArray arrayWithObjects:.*?\n\t\tnil\];\n\}}m, minimal_toolbar)

if source.include?('[array addObject:') ||
   source.include?('PhoneticToolbarItemIdentifier,') ||
   source.include?('SimplexToolbarItemIdentifier,') ||
   source.include?('UpdateToolbarItemIdentifier,') ||
   source.include?('GenericToolbarItemIdentifier,') ||
   source.include?('PluginToolbarItemIdentifier,')
  abort "TakaoPreference toolbar still exposes redundant panes"
end

if source == original
  abort "TakaoPreference toolbar modernization made no changes"
end

File.write(path, source)
RUBY
        preferences_ui_patch_applied=1
    fi

    if [[ -d "${preference_app_dir}/English.lproj" ]] && [[ -d "${preference_app_dir}/zh_TW.lproj" ]]; then
        ruby - "${preference_app_dir}" <<'RUBY'
require "cgi"
require "fileutils"

preference_dir = ARGV.fetch(0)
english_dir = File.join(preference_dir, "English.lproj")
traditional_dir = File.join(preference_dir, "zh_TW.lproj")
simplified_dir = File.join(preference_dir, "zh_CN.lproj")

def replace_xib_strings(path, replacements)
  source = File.read(path)
  original = source.dup

  replacements.each do |old_text, new_text|
    old_xml = CGI.escapeHTML(old_text)
    new_xml = CGI.escapeHTML(new_text)
    source.gsub!("<string key=\"NSContents\">#{old_xml}</string>", "<string key=\"NSContents\">#{new_xml}</string>")
    source.gsub!("<string key=\"NSTitle\">#{old_xml}</string>", "<string key=\"NSTitle\">#{new_xml}</string>")
  end

  File.write(path, source) if source != original
  source != original
end

replacements = {
  "Candidates:" => "候選窗：",
  "Highlight Color:" => "標示顏色：",
  "Beep on Error:" => "提示音：",
  "Enable alert sound" => "輸入錯誤時播放提示音",
  "... with this audio clip:" => "提示音效：",
  "… with this audio clip:" => "提示音效：",
  "Use Ctrl + Backslash to toggle Input Methods." => "輸入繁體時輸出簡體",
  "Shortcut Key:" => "",
  " to activate One-Key feature." => "",
  "Input Methods:" => "",
  "You can hide some Input Methods from the Input Menu." => "",
  "Keyboard Layout:" => "鍵盤配置：",
  "Smart Phonetic Input Method" => "注音設定",
  "Taditional Phonetic Input Method" => "傳統注音設定",
  "Cangjie Input Method" => "倉頡設定",
  "Simplex Input Method" => "簡易設定",
  "Character Set:" => "字元集：",
  "Allows non-big5 characters" => "允許非 Big5 字元",
  "Allow non-big5 characters" => "允許非 Big5 字元",
  "Put recently chosen candidates in front." => "優先顯示最近選用的候選字",
  "Clear radical reading when composition fails." => "組字錯誤時清除字根",
  "Compose at each keystroke." => "輸入字根時即時組字",
  "\"Clear radical reading when composition fails\" and Compose at each keystroke\" are mutally exclusive." => "「組字錯誤時清除字根」與「輸入字根時即時組字」不能同時啟用。",
  "Edit Phrases:" => "詞庫：",
  "Launch User Phrase Editor" => "開啟詞庫編輯器",
  "Check for Updates:" => "更新："
}

Dir.glob(File.join(english_dir, "*.xib")).each do |xib_path|
  replace_xib_strings(xib_path, replacements)
end

strings_path = File.join(traditional_dir, "Localizable.strings")
if File.exist?(strings_path)
  strings = File.read(strings_path)
  {
    "General" => "通用",
    "Phrase" => "詞庫",
    "Cangjie Blue" => "倉頡藍",
    "If you are nor running Yahoo! KeyKey, you are not able to check for update." => "如果倉頡星不在執行中，便無法執行更新檢查功能。",
    "If you are not runnung Yahoo! KeyKey, you are not able to export your database." => "如果倉頡星不在使用中，您便無法匯出自訂詞資料庫。",
    "If you are not runnung Yahoo! KeyKey, you are not able to import your database." => "如果倉頡星不在使用中，您便無法匯入自訂詞資料庫。",
    "Yahoo! KeyKey user phrases database was not found on your iDisk." => "在您的 iDisk 上找不到倉頡星的自訂詞資料庫備份。"
  }.each do |key, value|
    escaped_key = Regexp.escape(key)
    if strings =~ /^"#{escaped_key}"\s*=/
      strings.gsub!(/^"#{escaped_key}"\s*=\s*".*?";/, %Q{"#{key}" = "#{value}";})
    else
      strings << %Q{\n"#{key}" = "#{value}";\n}
    end
  end
  File.write(strings_path, strings)
end

info_plist_path = File.join(traditional_dir, "InfoPlist.strings")
if File.exist?(info_plist_path)
  info = File.read(info_plist_path)
  {
    "CFBundleName" => "倉頡星偏好設定",
    "CFBundleDisplayName" => "倉頡星偏好設定"
  }.each do |key, value|
    escaped_key = Regexp.escape(key)
    if info =~ /^#{escaped_key}\s*=/
      info.gsub!(/^#{escaped_key}\s*=\s*".*?";/, %Q{#{key} = "#{value}";})
    else
      info << %Q{\n#{key} = "#{value}";\n}
    end
  end
  File.write(info_plist_path, info)
end

%w[Localizable.strings InfoPlist.strings MainMenu.xib TakaoGenericSettings.xib TakaoReverseLookup.xib TakaoWordCount.xib].each do |filename|
  source_path = File.join(filename.end_with?(".xib") ? english_dir : traditional_dir, filename)
  next unless File.exist?(source_path)

  [english_dir, simplified_dir, traditional_dir].each do |target_dir|
    FileUtils.mkdir_p(target_dir)
    target_path = File.join(target_dir, filename)
    next if File.expand_path(source_path) == File.expand_path(target_path)
    FileUtils.cp(source_path, target_path)
  end
end
RUBY
        preferences_ui_patch_applied=1
    fi

    if ((preferences_ui_patch_applied)); then
        source_patch_applied "modernize-preferences-ui" "trimmed legacy preference panes, defaulted to the Cangjie pane, exposed Traditional-to-Simplified output, and forced Traditional Chinese resources."
    fi

    if [[ -d "${cerod_sqlite_dir}" ]] \
        && [[ ! -f "${cerod_sqlite_source}" ]] \
        && [[ -f "${sqlite_dir}/sqlite3.c" ]]; then
        cp "${sqlite_dir}/sqlite3.c" "${cerod_sqlite_source}"

        if [[ -f "${sqlite_dir}/sqlite3.h" ]]; then
            cp "${sqlite_dir}/sqlite3.h" "${cerod_sqlite_dir}/sqlite3.h"
        fi

        if [[ -f "${sqlite_dir}/sqlite3ext.h" ]]; then
            cp "${sqlite_dir}/sqlite3ext.h" "${cerod_sqlite_dir}/sqlite3ext.h"
        fi

        ruby -e 'File.open(ARGV[0], "a") do |file|
            file.write <<~SOURCE

                /*
                ** Probe-build stand-ins for the commercial SQLite SEE/CEROD codec APIs.
                ** The public SQLite amalgamation declares these functions but does not
                ** implement encryption. Returning SQLITE_OK keeps source compatibility
                ** checks linkable without claiming encrypted-database support.
                */
                SQLITE_API int sqlite3_key(sqlite3 *db, const void *pKey, int nKey)
                {
                  (void)db;
                  (void)pKey;
                  (void)nKey;
                  return SQLITE_OK;
                }

                SQLITE_API int sqlite3_rekey(sqlite3 *db, const void *pKey, int nKey)
                {
                  (void)db;
                  (void)pKey;
                  (void)nKey;
                  return SQLITE_OK;
                }

                SQLITE_API int sqlite3CodecAttach(sqlite3 *db, int iDb, const void *pKey, int nKey)
                {
                  (void)db;
                  (void)iDb;
                  (void)pKey;
                  (void)nKey;
                  return SQLITE_OK;
                }

                SQLITE_API void sqlite3CodecGetKey(sqlite3 *db, int iDb, void **ppKey, int *pnKey)
                {
                  (void)db;
                  (void)iDb;

                  if (ppKey) {
                    *ppKey = 0;
                  }

                  if (pnKey) {
                    *pnKey = 0;
                  }
                }

                SQLITE_API void sqlite3_activate_see(const char *zPassPhrase)
                {
                  (void)zPassPhrase;
                }

                SQLITE_API void sqlite3_activate_cerod(const char *zPassPhrase)
                {
                  (void)zPassPhrase;
                }
            SOURCE
        end' "${cerod_sqlite_source}"

        source_patch_applied "sqlite-cerod-public-stub" "substituted missing commercial sqlite-cerod-see source with bundled sqlite and probe codec stubs."
    fi

    if [[ ! -f "${cooked_keykey_database}" ]]; then
        mkdir -p "${cooked_database_dir}"

        if command -v sqlite3 >/dev/null 2>&1; then
            sqlite3 "${cooked_keykey_database}" 'PRAGMA user_version = 0;'
        else
            ruby -e 'File.binwrite(ARGV[0], "")' "${cooked_keykey_database}"
        fi

        source_patch_applied "cooked-db-placeholder" "created a minimal KeyKey.db placeholder for probe builds."
    fi

    if [[ -d "${dotmac_framework}" ]] \
        && { [[ ! -f "${dotmac_header}" ]] || [[ ! -f "${dotmac_binary}" ]] || ! grep -q 'kDMNetworkError' "${dotmac_header}" 2>/dev/null; }; then
        mkdir -p "${dotmac_framework}/Headers"
            ruby -e 'File.write(ARGV[0], <<~HEADER)
            #import <Foundation/Foundation.h>

            extern NSString * const kDMiDiskService;
            enum {
                kDMSuccess = 0,
                kDMNetworkError = 1,
                kDMResourceNotFound = 2,
                kDMServiceBusy = 3,
                kDMInvalidParameter = 4
            };

            @interface DMTransaction : NSObject
            - (BOOL)isSuccessful;
            - (id)result;
            - (BOOL)isFinished;
            - (unsigned long long)contentLength;
            - (unsigned long long)bytesTransferred;
            - (NSInteger)errorType;
            - (NSString *)localizedErrorString;
            @end

            @interface DMMemberAccount : NSObject
            + (void)signUpNewMemberWithApplicationID:(NSString *)applicationID;
            + (id)accountFromPreferencesWithApplicationID:(NSString *)applicationID;
            - (void)setApplicationName:(NSString *)applicationName;
            - (NSInteger)validateCredentials;
            - (void)setIsSynchronous:(BOOL)isSynchronous;
            - (DMTransaction *)servicesAvailableForAccount;
            @end

            @interface DMiDiskSession : NSObject
            + (id)iDiskSessionWithAccount:(DMMemberAccount *)account;
            - (void)setDelegate:(id)delegate;
            - (DMTransaction *)putData:(NSData *)data toPath:(NSString *)path;
            - (DMTransaction *)getDataAtPath:(NSString *)path;
            @end
        HEADER
        ' "${dotmac_header}"

        local dotmac_source="${SOURCE_PROBE_DIR}/DotMacKitStub.m"
        ruby -e 'File.write(ARGV[0], <<~SOURCE)
            #import <Foundation/Foundation.h>
            #import "DotMacKit.h"

            NSString * const kDMiDiskService = @"iDisk";

            @implementation DMTransaction
            - (BOOL)isSuccessful { return NO; }
            - (id)result { return nil; }
            - (BOOL)isFinished { return YES; }
            - (unsigned long long)contentLength { return 0; }
            - (unsigned long long)bytesTransferred { return 0; }
            - (NSInteger)errorType { return 0; }
            - (NSString *)localizedErrorString { return @"DotMacKit is unavailable on modern macOS."; }
            @end

            @implementation DMMemberAccount
            + (void)signUpNewMemberWithApplicationID:(NSString *)applicationID {}
            + (id)accountFromPreferencesWithApplicationID:(NSString *)applicationID { return [[[self alloc] init] autorelease]; }
            - (void)setApplicationName:(NSString *)applicationName {}
            - (NSInteger)validateCredentials { return 1; }
            - (void)setIsSynchronous:(BOOL)isSynchronous {}
            - (DMTransaction *)servicesAvailableForAccount { return [[[DMTransaction alloc] init] autorelease]; }
            @end

            @implementation DMiDiskSession
            + (id)iDiskSessionWithAccount:(DMMemberAccount *)account { return [[[self alloc] init] autorelease]; }
            - (void)setDelegate:(id)delegate {}
            - (DMTransaction *)putData:(NSData *)data toPath:(NSString *)path { return nil; }
            - (DMTransaction *)getDataAtPath:(NSString *)path { return nil; }
            @end
        SOURCE
        ' "${dotmac_source}"

        xcrun clang \
            -dynamiclib \
            -framework Foundation \
            -mmacosx-version-min=10.13 \
            -arch arm64 \
            -arch x86_64 \
            -I"${dotmac_framework}/Headers" \
            "${dotmac_source}" \
            -o "${dotmac_binary}" \
            -install_name "@rpath/DotMacKit.framework/DotMacKit"

        source_patch_applied "dotmackit-stub-framework" "created a DotMacKit stub framework for obsolete MobileMe APIs."
    fi

    if [[ -f "${dotmac_binary}" ]]; then
        codesign --force --sign - --timestamp=none "${dotmac_framework}" >/dev/null
    fi

    while IFS= read -r -d '' xib_file; do
        if grep -Eq 'IBDocument.SystemTarget">(0|10[0-5]0)|com.apple.InterfaceBuilder.CocoaPlugin.macosx|<integer value="10[0-5]0" key="NS.object.0"/>' "${xib_file}"; then
            ruby -0pi -e '
                gsub(%r{<int key="IBDocument.SystemTarget">0</int>}, %q{<int key="IBDocument.SystemTarget">1060</int>})
                gsub(%r{<int key="IBDocument.SystemTarget">10[0-5]0</int>}, %q{<int key="IBDocument.SystemTarget">1060</int>})
                gsub(%r{<integer value="10[0-5]0" key="NS.object.0"/>}, %q{<integer value="1060" key="NS.object.0"/>})
            ' "${xib_file}"
            xib_count=$((xib_count + 1))
        fi
    done < <(find "${source_root}" -name '*.xib' -print0 2>/dev/null)

    if [[ "${xib_count}" -gt 0 ]]; then
        source_patch_applied "xib-system-target-1060" "raised ${xib_count} XIB system target(s) to macOS 10.6."
    fi
}

apply_source_compat_patches
print_source_patch_summary

cook_basic_keykey_database() {
    local database_cooker_dir="${source_root}/Distributions/Takao/DatabaseCooker"
    local cooked_keykey_database="${source_root}/Distributions/Takao/CookedDatabase/KeyKey.db"
    local database_version="${SOURCE_DATABASE_VERSION:-${source_root##*-}}"
    local cangjie_entry_count
    local associated_phrase_count

    if [[ ! -d "${database_cooker_dir}" ]]; then
        echo "Database cooker was not found: ${database_cooker_dir}" >&2
        return 1
    fi

    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo "sqlite3 is required to cook the basic KeyKey database." >&2
        return 1
    fi

    if ! ruby -e 'require "sqlite3"' >/dev/null 2>&1; then
        echo "Ruby sqlite3 gem is required to cook the basic KeyKey database." >&2
        return 1
    fi

    echo "Cooking basic KeyKey database from open CIN tables..."
    echo "Database log: ${SOURCE_DATABASE_LOG}"

    rm -f "${cooked_keykey_database}"

    if ! make -C "${database_cooker_dir}" \
        SQLITE3=sqlite3 \
        DB=../CookedDatabase/KeyKey.db \
        >"${SOURCE_DATABASE_LOG}" 2>&1; then
        echo "Database cooking failed. Last 120 log lines:"
        tail -n 120 "${SOURCE_DATABASE_LOG}"
        return 1
    fi

    sqlite3 "${cooked_keykey_database}" <<SQL
CREATE TABLE IF NOT EXISTS cooked_information (key, value);
DELETE FROM cooked_information WHERE key = 'version';
INSERT INTO cooked_information (key, value) VALUES ('version', '${database_version}');
SQL

    ruby "${PROJECT_DIR}/tools/cook-associated-phrases.rb" "${source_root}" "${cooked_keykey_database}" \
        >>"${SOURCE_DATABASE_LOG}" 2>&1

    cangjie_entry_count="$(sqlite3 "${cooked_keykey_database}" "SELECT COUNT(*) FROM 'Generic-cj-cin';")"
    associated_phrase_count="$(sqlite3 "${cooked_keykey_database}" "SELECT COUNT(*) FROM associated_phrases;")"

    if [[ -z "${cangjie_entry_count}" ]] || [[ "${cangjie_entry_count}" == "0" ]]; then
        echo "Cooked KeyKey database does not contain Cangjie entries." >&2
        return 1
    fi

    if [[ -z "${associated_phrase_count}" ]] || [[ "${associated_phrase_count}" == "0" ]]; then
        echo "Cooked KeyKey database does not contain associated phrases." >&2
        return 1
    fi

    echo "Cooked basic KeyKey database with ${cangjie_entry_count} Cangjie entries."
    echo "Cooked ${associated_phrase_count} associated phrase heads."
    echo "Registered cooked database version ${database_version}."
    echo
}

if [[ "${PROBE_BUILD:-0}" == "1" ]]; then
    if ! cook_basic_keykey_database; then
        if [[ -n "${SOURCE_BUILD_APP}" ]]; then
            exit 1
        fi

        echo "Continuing compile probe with the minimal placeholder database."
        echo
    fi
fi

echo "Upstream: ${UPSTREAM_REPO}"
echo "Commit: $("${GIT_CMD}" -C "${SOURCE_REPO_DIR}" rev-parse --short HEAD)"
echo "Source root: ${source_root}"
echo

list_targets() {
    local project="$1"
    local pbxproj="${project}/project.pbxproj"

    echo "Project: $(basename "${project}")"
    echo "Targets:"
    plutil -convert json -o - "${pbxproj}" \
        | ruby -W0 -rjson -e '
            project = JSON.parse($stdin.read)
            targets = project.fetch("objects").values
                .select { |object| object["isa"] == "PBXNativeTarget" }
                .map { |object| object["name"] }
                .compact
                .sort
            targets.each { |target| puts "  - #{target}" }
        '
    echo
}

for project in "${source_root}"/*.xcodeproj; do
    [[ -d "${project}" ]] || continue
    list_targets "${project}"
done

xcodebuild_version_output="$(xcodebuild -version 2>&1)" || {
    if xcrun_policy_error "${xcodebuild_version_output}"; then
        print_xcode_recovery "xcodebuild"
        exit 0
    fi

    echo "Full Xcode is not active. Install Xcode, then run:"
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    if [[ -n "${xcodebuild_version_output}" ]]; then
        echo
        echo "xcodebuild output:"
        printf '%s\n' "${xcodebuild_version_output}" | sed 's/^/  /'
    fi
    echo
    echo "After that, run this probe again or try:"
    echo "  PROBE_BUILD=1 make probe-source"
    exit 0
}

echo "Xcode:"
printf '%s\n' "${xcodebuild_version_output}"
echo

for project in "${source_root}"/*.xcodeproj; do
    [[ -d "${project}" ]] || continue
    xcodebuild -list -project "${project}"
done

if [[ "${PROBE_BUILD:-0}" != "1" ]]; then
    echo
    echo "Skipping compile probe. Set PROBE_BUILD=1 to try an Xcode build."
    exit 0
fi

echo
echo "Trying a first IMK loader build probe..."
echo "Build log: ${SOURCE_BUILD_LOG}"

if ! xcodebuild \
    -project "${source_root}/Takao.xcodeproj" \
    -target "Takao (Loader OSX-IMK)" \
    -configuration Release \
    -sdk macosx \
    ARCHS="${SOURCE_ARCHS}" \
    ONLY_ACTIVE_ARCH=NO \
    MACOSX_DEPLOYMENT_TARGET="${SOURCE_DEPLOYMENT_TARGET}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build >"${SOURCE_BUILD_LOG}" 2>&1; then
    echo "Xcode build failed. Last 200 log lines:"
    tail -n 200 "${SOURCE_BUILD_LOG}"
    exit 1
fi

echo "Xcode build succeeded."

built_app="${source_root}/build/Release/Yahoo! KeyKey.app"

if [[ -n "${SOURCE_BUILD_APP}" ]]; then
    if [[ ! -d "${built_app}" ]]; then
        echo "Build finished, but expected app was not found: ${built_app}" >&2
        exit 1
    fi

    rm -rf "${SOURCE_BUILD_APP}"
    mkdir -p "$(dirname "${SOURCE_BUILD_APP}")"
    ditto --norsrc --noextattr --noqtn --noacl --nopersistRootless "${built_app}" "${SOURCE_BUILD_APP}"
    echo
    echo "Copied source-built app to ${SOURCE_BUILD_APP}"
fi
