#!/bin/bash

#
#  uninstall.sh
#  Bootstrap Buddy
#
#  Copyright 2024 Inetum Poland
#
#  Based on Escrow Buddy
#  Copyright 2023 Netflix
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

#  This script uninstalls Bootstrap Buddy.

set -euo pipefail

readonly AUTH_DB_SECTION="system.login.console"
readonly MECHANISM_LABEL="Bootstrap Buddy:Invoke,privileged"
readonly RECEIPT_ID="com.inetum.Bootstrap-Buddy"
readonly BUNDLE_PATH="/Library/Security/SecurityAgentPlugins/Bootstrap Buddy.bundle"
readonly BUNDLED_TEARDOWN="${BUNDLE_PATH}/Contents/Resources/AuthDBTeardown.sh"

BB_DIR=""
AUTH_DB=""

log() {
    echo "$1"
}

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

cleanup() {
    if [[ -n "${BB_DIR}" && -d "${BB_DIR}" ]]; then
        rm -rf "${BB_DIR}"
    fi
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        fail "This script must be run as root."
    fi
}

create_workspace() {
    BB_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/com.inetum.Bootstrap-Buddy.XXXXXX") || fail "Unable to create a temporary workspace."
    AUTH_DB="${BB_DIR}/auth.db"
}

read_auth_db() {
    log "Reading ${AUTH_DB_SECTION} section of authorization database..."

    if ! /usr/bin/security authorizationdb read "${AUTH_DB_SECTION}" > "${AUTH_DB}"; then
        fail "Unable to read the current authorization database."
    fi

    if [[ ! -s "${AUTH_DB}" ]]; then
        fail "Authorization database output is empty."
    fi

    if ! /usr/bin/plutil -lint "${AUTH_DB}" >/dev/null; then
        fail "Authorization database output is not a valid property list."
    fi
}

authdb_has_mechanism() {
    grep -Fq "<string>${MECHANISM_LABEL}</string>" "${AUTH_DB}"
}

find_mechanism_index() {
    local raw_index

    raw_index="$(
        /usr/libexec/PlistBuddy -c "Print :mechanisms:" "${AUTH_DB}" 2>/dev/null \
            | grep -nF "${MECHANISM_LABEL}" \
            | awk -F ":" 'NR == 1 { print $1 }' || true
    )"

    if [[ -z "${raw_index}" ]]; then
        return 1
    fi

    raw_index=$((raw_index - 2))
    if (( raw_index < 0 )); then
        return 1
    fi

    echo "${raw_index}"
}

run_internal_teardown() {
    local mechanism_index

    read_auth_db
    if ! authdb_has_mechanism; then
        log "Bootstrap Buddy is not configured in the loginwindow authorization database."
        return 0
    fi

    cp "${AUTH_DB}" "${AUTH_DB}.backup" || fail "Unable to back up the current authorization database."

    mechanism_index="$(find_mechanism_index)" || fail "Unable to locate Bootstrap Buddy in the current authorization database."

    log "Removing Bootstrap Buddy from authorization database..."
    if ! /usr/libexec/PlistBuddy -c "Delete :mechanisms:${mechanism_index}" "${AUTH_DB}"; then
        fail "Unable to remove Bootstrap Buddy from the authorization database."
    fi

    if ! /usr/bin/security authorizationdb write "${AUTH_DB_SECTION}" < "${AUTH_DB}"; then
        fail "Unable to save changes to the authorization database."
    fi
}

ensure_authdb_mechanism_removed() {
    if [[ -x "${BUNDLED_TEARDOWN}" ]]; then
        log "Running bundled authorization database teardown..."
        if "${BUNDLED_TEARDOWN}"; then
            read_auth_db
            if ! authdb_has_mechanism; then
                return 0
            fi

            log "Bundled teardown completed, but Bootstrap Buddy is still configured in the authorization database."
        else
            log "Bundled teardown failed."
        fi

        log "Falling back to built-in authorization database teardown..."
    fi

    run_internal_teardown
    read_auth_db
    if authdb_has_mechanism; then
        fail "Bootstrap Buddy is still configured in the authorization database. Aborting before removing the bundle."
    fi
}

remove_bundle() {
    if [[ ! -e "${BUNDLE_PATH}" ]]; then
        log "Bootstrap Buddy bundle is already absent."
        return 0
    fi

    log "Deleting Bootstrap Buddy bundle..."
    rm -rf "${BUNDLE_PATH}" || fail "Unable to delete the Bootstrap Buddy bundle."

    if [[ -e "${BUNDLE_PATH}" ]]; then
        fail "Bootstrap Buddy bundle still exists after deletion."
    fi
}

forget_receipt() {
    if ! /usr/sbin/pkgutil --pkg-info "${RECEIPT_ID}" >/dev/null 2>&1; then
        log "Bootstrap Buddy receipt is already absent."
        return 0
    fi

    log "Forgetting receipt..."
    if ! /usr/sbin/pkgutil --forget "${RECEIPT_ID}" >/dev/null; then
        fail "Unable to forget package receipt ${RECEIPT_ID}."
    fi
}

main() {
    trap cleanup EXIT

    require_root
    create_workspace
    read_auth_db

    if authdb_has_mechanism; then
        ensure_authdb_mechanism_removed
    else
        log "Bootstrap Buddy is not configured in the loginwindow authorization database."
    fi

    remove_bundle
    forget_receipt

    log "Bootstrap Buddy successfully uninstalled."
}

main "$@"
