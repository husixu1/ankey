#!/bin/bash
# shellcheck disable=SC2178

# Log functions: Info / Warning / Error / Critical
ankey.__log() { local l='' && for l in "$@"; do echo "$l"$'\033[0m'; done; }
ankey.inf() { ankey.__log "${@/#/$'\033[92m'" [INF] "$'\033[0m'}"; }
ankey.wrn() { ankey.__log "${@/#/$'\033[93m'" [WRN] "}" 1>&2; }
ankey.err() { ankey.__log "${@/#/$'\033[91m'" [ERR] "}" 1>&2; }
ankey.crt() { ankey.err "$@" && exit 1; }

ankey.prereq() {
    # Check bash version
    [[ ${BASH_VERSINFO[0]}${BASH_VERSINFO[1]} -ge 50 ]] ||
        ankey.crt "Bash 5.0 or later required"

    # Check required executables
    local -ra exes=(fzf openssl termux-fingerprint termux-keystore)
    for exe in "${exes[@]}"; do
        command -v "$exe" >/dev/null 2>&1 ||
            ankey.crt "Required executable not found: $exe"
    done

    # Check for biometric auth availability
    ankey.__check_bio_auth_availablity || return

    # Create the config directory if not exists
    mkdir -p "$HOME"/.config/ankey
}

ankey.parse_args() {
    local -n _rc="$1" && shift
    local read_opts=true
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -*) $read_opts || ankey.crt "Unknown option: $1" ;;&
        -c | --config) shift && _rc[CONFIG_FILE]="$1" ;;
        -f | --fzf) shift && _rc[FZF]="$1" ;;
        -i | --iters) shift && _rc[OPENSSL_ITERS]="$1" ;;
        -a | --alias) shift && _rc[NONCE_KEY_ALIAS]="$1" ;;
        --) read_opts=false ;;
        *) ankey.err "Unknown option: $1" && return 1 ;;
        esac
        shift
    done
}

# $1: Options dict name
ankey.load_config() {
    local -n _rc="$1"

    # Check for config file. If not exists, just return and use defaults
    [[ -f "${_rc[CONFIG_FILE]}" ]] || return 0

    # Read the config file
    local -ra valid_configs="(${_rc[CONFIGS_TO_SAVE]})"
    while IFS='' read -r line; do
        # Skip comments and empty lines
        [[ $line == '#'* || $line == '' ]] && continue
        (IFS='|' && [[ ! $line =~ ^("${valid_configs[*]}")'=' ]]) || {
            ankey.err "Invalid config line: $line"
            return 1
        }
        _rc[${line%%=*}]="${line#*=}"
    done <"${_rc[CONFIG_FILE]}"
}

# $1: Options dict name
ankey.save_config() {
    local -n _rc="$1"
    local -ra valid_configs="(${_rc[CONFIGS_TO_SAVE]})"
    {
        printf '%s\n' "# Ankey config file, DO NOT EDIT MANUALLY."
        for key in "${!_rc[@]}"; do
            (IFS='|' && [[ ! $key =~ ^(${valid_configs[*]})$ ]]) ||
                printf "%s=%s\n" "$key" "${_rc[$key]}"
        done
    } >|"${_rc[CONFIG_FILE]}"
}

# $1: Name of the variable that stores the sensitive information
# shellcheck disable=SC2179
ankey.__clear_sensitive_var() {
    local -n _var="$1"
    local k=''
    case "${_var@a}" in
    *a* | *A*) for k in "${!_var[@]}"; do
        _var["$k"]='' && for _ in $(seq "${#_var["$k"]}"); do _var["$k"]+="$RANDOM"; done
        _var["$k"]='' && for _ in $(seq 10000); do _var["$k"]+="$RANDOM"; done
        unset "_var[$k]"
    done ;;
    *) {
        _var='' && for _ in $(seq "${#_var}"); do _var+="$RANDOM"; done
        _var='' && for _ in $(seq 10000); do _var+="$RANDOM"; done
        unset _var
    } ;;
    esac
    unset "$1" || true
}

# Read password securely and print it to stdout without '\n' (prompt on stderr)
# $1: Prompt string
ankey.__askpass() {
    local prompt=" $1 " passwd='' char=''
    while IFS='' read -p "$prompt" -r -s -n 1 char; do
        [[ $char != $'\0' ]] || break
        [[ $char != $'\x7f' ]] || {
            [[ "${#passwd}" -gt 0 ]] || { prompt=$'' && continue; }
            prompt=$'\b \b' && passwd="${passwd%?}" && continue
            printf "%s" "$char" >&"${_ss[IN]}"
        }
        prompt='*'
        passwd+="$char"
    done
    printf "%s" "$passwd"

    # Clear the password from memory
    ankey.__clear_sensitive_var passwd
    printf %s $'\033[2K\r' >&2
}

# $1: Options dict name
# $2: Session dict name
# $3: Name of the variable that stores the resulting choice (will be cleared)
# $4: Choices array name
# $5: Prompt string
# shellcheck disable=SC2034
ankey.fzf() {
    local tmp=''
    local -n _rc="$1" _ss="$2" _res="${3:-tmp}" _choices="$4"
    local prompt="$5"
    local -a fzf_opts="(${_ss[FZF_OPTS]} --delimiter=:: --with-nth=-1)"
    _res=''
    while [[ -z "$_res" ]]; do
        _res="$( # Run fzf and capture the result
            "${_rc[FZF]}" "${fzf_opts[@]}" --border-label=" $prompt " < <(#
                IFS=$'\n' && printf %s "${_choices[*]}"
            )
        )"
    done
}

ankey.__press_to_continue() {
    read -n1 -r -p " Press any key to continue ..."
}

ankey.__check_bio_auth_availablity() {
    command -v termux-fingerprint >/dev/null 2>&1 || {
        ankey.err "termux-fingerprint not found. Please install termux-api."
        return 1
    }
}

ankey.__check_encryption_availablity() {
    local -n _rc="$1"
    command -v termux-keystore >/dev/null 2>&1 || {
        ankey.err "termux-keystore not found. Please install termux-api."
        return 1
    }

    [[ $(termux-keystore list) == *'"alias": "'"${_rc[NONCE_KEY_ALIAS]}"'"'* ]] || {
        ankey.err "Key '${_rc[NONCE_KEY_ALIAS]}' not found in keystore."
        return 1
    }

    [[ "${_rc[NONCE]}" ]] || {
        ankey.err "Nonce cannot be empty. Please run biometric setup first."
        return 1
    }
}

# $1: Options dict name
# $2: Session dict name
# $3: Name of the variable that stores the bio key (will be cleared)
ankey.__auth_to_get_bio_key() {
    local -n _rc="$1" _ss="$2" _res="$3"
    ankey.__check_bio_auth_availablity || return
    ankey.__check_encryption_availablity "$1" || return

    local termux_fp_output=''
    { termux_fp_output="$(termux-fingerprint)" &&
        [[ $termux_fp_output == *'AUTH_RESULT_SUCCESS'* ]]; } || {
        ankey.err "Termux fingerprint auth failed"
        return 1
    }

    # Sign a nonce with the generated key
    _res="$(base64 -w 0 < <(#
        termux-keystore sign "${_rc[NONCE_KEY_ALIAS]}" SHA256withRSA < <(#
            printf %s "${_rc[NONCE]}"
        )
    ))"
}

# $1: Options dict name
# $2: Session dict name
# Input: Strings to encrypt, one per line (with trailing '\n')
# Output: Encrypted strings, one per line (with trailing '\n')
ankey.__bio_encrypt() {
    local -n _rc="$1" _ss="$2"

    local key=''
    ankey.__auth_to_get_bio_key "$1" "$2" key || return

    # Encrypt the secrets with the signed nonce
    local secret=''
    while IFS='' builtin read -r secret; do
        # See https://security.stackexchange.com/questions/3959
        openssl enc -aes-256-cbc -base64 -A \
            -iter "${_rc[OPENSSL_ITERS]}" -pbkdf2 \
            -pass file:<(builtin printf %s "$key") \
            -in <(builtin printf %s "$secret") || return
        echo # Add a newline
    done

    # Clear the signed nonce for security
    ankey.__clear_sensitive_var key
}

# $1: Options dict name
# $2: Session dict name
# Input: Strings to decrypt, one per line (with trailing '\n')
# Output: Decrypted strings, one per line (with trailing '\n')
ankey.__bio_decrypt() {
    local -n _rc="$1" _ss="$2"

    local key=''
    ankey.__auth_to_get_bio_key "$1" "$2" key || return

    # Decrypt the secrets with the signed nonce
    local secret=''
    while IFS='' builtin read -r secret; do
        openssl enc -d -aes-256-cbc -base64 -A \
            -iter "${_rc[OPENSSL_ITERS]}" -pbkdf2 \
            -pass file:<(builtin printf %s "$key") \
            -in <(builtin printf %s "$secret") || return
        echo # Add a newline
    done

    # Clear the signed nonce for security
    ankey.__clear_sensitive_var key
}

# $1: Options dict name
# $2: Session dict name
# $3: Name of the variable that stores the next action
# shellcheck disable=SC2034 disable=SC2153
ankey.action.select_action() {
    local -n _rc="$1" _ss="$2" _act="$3"

    # Load the password list
    local -A passwd_dict="${_rc[PW_DICT]}"
    local -a passwd_list=("${!passwd_dict[@]}")
    local -a actions=()
    mapfile -t actions < <(#
        for k in "${passwd_list[@]}"; do printf '%s\n' "$k"; done | sort
    )
    for i in "${!passwd_list[@]}"; do
        actions["$i"]="type_passwd::$((i + 1)). Type '${passwd_list["$i"]}'"
    done
    [[ "${#actions[@]}" -eq 0 ]] || actions+=(select_action::)

    # Add the rest of the actions
    actions+=(
        setup_biometric::"[1] Setup biometric auth"
        add_password::'[2] Add password'
        del_password::'[3] Delete password'
        select_action::''
        quit::'[0] Quit'
    )

    local choice=''
    ankey.fzf "$1" "$2" choice actions "Choose an action"
    _act="${choice%%::*}"
    [[ "$choice" != 'type_passwd::'* ]] || {
        choice="${choice%%.*}"
        _ss[CHOICE]="${passwd_list["$((${choice#*::} - 1))"]}"
    }
}

ankey.action.setup_biometric() {
    local -n _rc="$1" _ss="$2" _act="$3"
    _act='select_action'

    ankey.__check_bio_auth_availablity || {
        ankey.__press_to_continue
        return
    }

    # Generate a new nonce if not exit
    [[ "${_rc[NONCE]}" ]] || {
        ankey.inf "Generating a new nonce ..."
        _rc[NONCE]="$(openssl rand -base64 32)"
    }

    # Return if the key already exists
    [[ $(termux-keystore list) != *'"alias": "'"${_rc[NONCE_KEY_ALIAS]}"'"'* ]] || {
        ankey.wrn "Key '${_rc[NONCE_KEY_ALIAS]}' already exists in keystore."
        ankey.__press_to_continue
        return
    }

    # Generate a new key with 3-second validity, if not already exists
    ankey.inf "Generating a new key with termux-keystore ..."
    termux-keystore generate "${_rc[NONCE_KEY_ALIAS]}" -a RSA -s 4096 -u 3 || {
        ankey.err "Failed to generate key with termux-keystore"
        ankey.__press_to_continue
        return
    }

    # Test fingerprint auth here
    local passwd='' enc_passwd='' dec_passwd=''
    passwd="$(openssl rand -base64 32)"
    ankey.inf "Testing biometric encryption ..."
    enc_passwd="$(ankey.__bio_encrypt "$1" "$2" < <(#
        builtin printf '%s\n' "$passwd"
    ))" || {
        ankey.crt "Internal Error: Failed to encrypt the test password"
        ankey.__press_to_continue
        return
    }
    ankey.inf "Testing biometric decryption ..."
    dec_passwd="$(ankey.__bio_decrypt "$1" "$2" < <(#
        builtin printf '%s\n' "$enc_passwd"
    ))" || {
        ankey.crt "Internal Error: Failed to decrypt the test password"
        ankey.__press_to_continue
        return
    }
    [[ "$dec_passwd" == "$passwd" ]] || {
        typeset -p passwd enc_passwd dec_passwd
        ankey.crt "Internal error: Password test: decrypted != original"
        ankey.__press_to_continue
        return
    }
    ankey.__clear_sensitive_var passwd
    ankey.__clear_sensitive_var enc_passwd
    ankey.__clear_sensitive_var dec_passwd
}

ankey.action.add_password() {
    local -n _rc="$1" _ss="$2" _act="$3"
    _act='select_action'

    # Require biometric auth key already setup
    ankey.__check_encryption_availablity "$1" || {
        ankey.__press_to_continue
        return
    }

    local -A passwds="${_rc[PW_DICT]}"
    local name='' passwd='' passwds_cmd=''
    while true; do
        IFS= read -r -p " Name the password: " -e -i "$name" name
        [[ "$name" ]] || { ankey.wrn "Name cannot be empty" && continue; }
        [[ -z "${passwds["$name"]}" ]] || { ankey.wrn "'$name' already exists" && continue; }
        break
    done

    while true; do
        passwd="$(ankey.__askpass "Password to encrypt:")"
        [[ "$passwd" ]] || { ankey.wrn "Password cannot be empty" && continue; }
        break
    done

    # Encrypt the password if biometric auth is enabled
    ankey.inf "Encrypting password ..."
    passwd="$(ankey.__bio_encrypt "$1" "$2" < <(#
        builtin printf '%s\n' "$passwd"
    ))" || {
        ankey.__clear_sensitive_var passwd
        ankey.err "Failed to encrypt the password"
        ankey.__press_to_continue
        return
    }
    passwds["$name"]="$passwd"
    passwds_cmd="$(typeset -p passwds)"
    _rc[PW_DICT]="${passwds_cmd#*passwds=}"

    ankey.__clear_sensitive_var passwd
}

ankey.action.del_password() {
    local -n _rc="$1" _ss="$2" _act="$3"
    _act='select_action'

    # Load the password list
    local -A passwd_dict="${_rc[PW_DICT]}"
    [[ "${#passwd_dict[@]}" ]] || {
        ankey.wrn "No password to delete"
        ankey.__press_to_continue
        return
    }

    local -a passwd_list=("${!passwd_dict[@]}")
    local -a actions=()
    mapfile -t actions < <(#
        for k in "${passwd_list[@]}"; do printf '%s\n' "$k"; done | sort
    )
    for i in "${!passwd_list[@]}"; do
        actions["$i"]="delete::$((i + 1)). Delete '${passwd_list["$i"]}'"
    done
    [[ "${#actions[@]}" -eq 0 ]] || actions+=(select_action::)

    # Add the rest of the actions
    actions+=(
        select_action::''
        quit::'[0] Quit'
        select_action::'' # Prevent accidental quit
    )

    local choice=''
    ankey.fzf "$1" "$2" choice actions "Choose an action"
    [[ "$choice" != 'delete::'* ]] || {
        choice="${choice%%.*}"
        unset "passwd_dict[${passwd_list["$((${choice#*::} - 1))"]}]"
        local passwds_cmd=''
        passwds_cmd="$(typeset -p passwd_dict)"
        _rc[PW_DICT]="${passwds_cmd#*passwd_dict=}"
    }
}

ankey.__check_hid_availablity() {
    local -n _rc="$1"
    sudo test -c "${_rc[HID_DEVICE]}" || {
        ankey.err "HID device not found. Please set it up accordingly."
        return 1
    }
}

# shellcheck disable=SC2059
# $1: Options dict name
# $2: password to type
ankey.__type_passwd() {
    local -n _rc="$1"
    local passwd="$2"

    local -rA keys=(
        ['a']='\x00\x00\x04\x00\x00\x00\x00\x00' ['A']='\x02\x00\x04\x00\x00\x00\x00\x00'
        ['b']='\x00\x00\x05\x00\x00\x00\x00\x00' ['B']='\x02\x00\x05\x00\x00\x00\x00\x00'
        ['c']='\x00\x00\x06\x00\x00\x00\x00\x00' ['C']='\x02\x00\x06\x00\x00\x00\x00\x00'
        ['d']='\x00\x00\x07\x00\x00\x00\x00\x00' ['D']='\x02\x00\x07\x00\x00\x00\x00\x00'
        ['e']='\x00\x00\x08\x00\x00\x00\x00\x00' ['E']='\x02\x00\x08\x00\x00\x00\x00\x00'
        ['f']='\x00\x00\x09\x00\x00\x00\x00\x00' ['F']='\x02\x00\x09\x00\x00\x00\x00\x00'
        ['g']='\x00\x00\x0a\x00\x00\x00\x00\x00' ['G']='\x02\x00\x0a\x00\x00\x00\x00\x00'
        ['h']='\x00\x00\x0b\x00\x00\x00\x00\x00' ['H']='\x02\x00\x0b\x00\x00\x00\x00\x00'
        ['i']='\x00\x00\x0c\x00\x00\x00\x00\x00' ['I']='\x02\x00\x0c\x00\x00\x00\x00\x00'
        ['j']='\x00\x00\x0d\x00\x00\x00\x00\x00' ['J']='\x02\x00\x0d\x00\x00\x00\x00\x00'
        ['k']='\x00\x00\x0e\x00\x00\x00\x00\x00' ['K']='\x02\x00\x0e\x00\x00\x00\x00\x00'
        ['l']='\x00\x00\x0f\x00\x00\x00\x00\x00' ['L']='\x02\x00\x0f\x00\x00\x00\x00\x00'
        ['m']='\x00\x00\x10\x00\x00\x00\x00\x00' ['M']='\x02\x00\x10\x00\x00\x00\x00\x00'
        ['n']='\x00\x00\x11\x00\x00\x00\x00\x00' ['N']='\x02\x00\x11\x00\x00\x00\x00\x00'
        ['o']='\x00\x00\x12\x00\x00\x00\x00\x00' ['O']='\x02\x00\x12\x00\x00\x00\x00\x00'
        ['p']='\x00\x00\x13\x00\x00\x00\x00\x00' ['P']='\x02\x00\x13\x00\x00\x00\x00\x00'
        ['q']='\x00\x00\x14\x00\x00\x00\x00\x00' ['Q']='\x02\x00\x14\x00\x00\x00\x00\x00'
        ['r']='\x00\x00\x15\x00\x00\x00\x00\x00' ['R']='\x02\x00\x15\x00\x00\x00\x00\x00'
        ['s']='\x00\x00\x16\x00\x00\x00\x00\x00' ['S']='\x02\x00\x16\x00\x00\x00\x00\x00'
        ['t']='\x00\x00\x17\x00\x00\x00\x00\x00' ['T']='\x02\x00\x17\x00\x00\x00\x00\x00'
        ['u']='\x00\x00\x18\x00\x00\x00\x00\x00' ['U']='\x02\x00\x18\x00\x00\x00\x00\x00'
        ['v']='\x00\x00\x19\x00\x00\x00\x00\x00' ['V']='\x02\x00\x19\x00\x00\x00\x00\x00'
        ['w']='\x00\x00\x1a\x00\x00\x00\x00\x00' ['W']='\x02\x00\x1a\x00\x00\x00\x00\x00'
        ['x']='\x00\x00\x1b\x00\x00\x00\x00\x00' ['X']='\x02\x00\x1b\x00\x00\x00\x00\x00'
        ['y']='\x00\x00\x1c\x00\x00\x00\x00\x00' ['Y']='\x02\x00\x1c\x00\x00\x00\x00\x00'
        ['z']='\x00\x00\x1d\x00\x00\x00\x00\x00' ['Z']='\x02\x00\x1d\x00\x00\x00\x00\x00'
        ['1']='\x00\x00\x1e\x00\x00\x00\x00\x00' ['!']='\x02\x00\x1e\x00\x00\x00\x00\x00'
        ['2']='\x00\x00\x1f\x00\x00\x00\x00\x00' ['@']='\x02\x00\x1f\x00\x00\x00\x00\x00'
        ['3']='\x00\x00\x20\x00\x00\x00\x00\x00' ['#']='\x02\x00\x20\x00\x00\x00\x00\x00'
        ['4']='\x00\x00\x21\x00\x00\x00\x00\x00' ['$']='\x02\x00\x21\x00\x00\x00\x00\x00'
        ['5']='\x00\x00\x22\x00\x00\x00\x00\x00' ['%']='\x02\x00\x22\x00\x00\x00\x00\x00'
        ['6']='\x00\x00\x23\x00\x00\x00\x00\x00' ['^']='\x02\x00\x23\x00\x00\x00\x00\x00'
        ['7']='\x00\x00\x24\x00\x00\x00\x00\x00' ['&']='\x02\x00\x24\x00\x00\x00\x00\x00'
        ['8']='\x00\x00\x25\x00\x00\x00\x00\x00' ['*']='\x02\x00\x25\x00\x00\x00\x00\x00'
        ['9']='\x00\x00\x26\x00\x00\x00\x00\x00' ['(']='\x02\x00\x26\x00\x00\x00\x00\x00'
        ['0']='\x00\x00\x27\x00\x00\x00\x00\x00' [')']='\x02\x00\x27\x00\x00\x00\x00\x00'
        [' ']='\x00\x00\x2c\x00\x00\x00\x00\x00'
        ['-']='\x00\x00\x2d\x00\x00\x00\x00\x00' ['_']='\x02\x00\x2d\x00\x00\x00\x00\x00'
        ['=']='\x00\x00\x2e\x00\x00\x00\x00\x00' ['+']='\x02\x00\x2e\x00\x00\x00\x00\x00'
        ['[']='\x00\x00\x2f\x00\x00\x00\x00\x00' ['{']='\x02\x00\x2f\x00\x00\x00\x00\x00'
        [']']='\x00\x00\x30\x00\x00\x00\x00\x00' ['}']='\x02\x00\x30\x00\x00\x00\x00\x00'
        ["\\"]='\x00\x00\x31\x00\x00\x00\x00\x00' ['|']='\x02\x00\x31\x00\x00\x00\x00\x00'
        [';']='\x00\x00\x33\x00\x00\x00\x00\x00' [':']='\x02\x00\x33\x00\x00\x00\x00\x00'
        ["'"]='\x00\x00\x34\x00\x00\x00\x00\x00' ['"']='\x02\x00\x34\x00\x00\x00\x00\x00'
        ['`']='\x00\x00\x35\x00\x00\x00\x00\x00' ['~']='\x02\x00\x35\x00\x00\x00\x00\x00'
        [',']='\x00\x00\x36\x00\x00\x00\x00\x00' ['<']='\x02\x00\x36\x00\x00\x00\x00\x00'
        ['.']='\x00\x00\x37\x00\x00\x00\x00\x00' ['>']='\x02\x00\x37\x00\x00\x00\x00\x00'
        ['/']='\x00\x00\x38\x00\x00\x00\x00\x00' ['?']='\x02\x00\x38\x00\x00\x00\x00\x00'
        [$'\t']='\x00\x00\x2b\x00\x00\x00\x00\x00'
    )

    local cmd=''
    for ((i = 0; i < "${#passwd}"; ++i)); do
        cmd+="builtin printf ${keys["${passwd:$i:1}"]@Q} >${_rc[HID_DEVICE]@Q}"$'\n'
        cmd+="builtin printf '"'\x00\x00\x00\x00\x00\x00\x00\x00'"' >${_rc[HID_DEVICE]@Q}"$'\n'
    done
    sudo bash -c "$cmd"
    ankey.__clear_sensitive_var cmd
    ankey.__clear_sensitive_var passwd
}

ankey.action.type_passwd() {
    local -n _rc="$1" _ss="$2" _act="$3"
    _act='select_action'

    [[ "${_ss[CHOICE]}" ]] || {
        ankey.wrn "No password selected"
        ankey.__press_to_continue
        return
    }

    ankey.__check_hid_availablity "$1" || {
        ankey.err "HID functionality not available"
        ankey.__press_to_continue
        return
    }

    sudo true || {
        ankey.err "Failed to get sudo privileges"
        ankey.__press_to_continue
        return
    }

    local -A passwds="${_rc[PW_DICT]}"
    local encrypted_passwd="${passwds["${_ss[CHOICE]}"]}"
    [[ "$encrypted_passwd" ]] || {
        ankey.err "Password not found"
        ankey.__press_to_continue
        return
    }

    local passwd=''
    passwd="$(ankey.__bio_decrypt "$1" "$2" < <(#
        builtin printf '%s\n' "$encrypted_passwd"
    ))" || {
        ankey.err "Failed to decrypt the password"
        ankey.__press_to_continue
        return
    }

    # Type the password
    ankey.inf "Typing the password ..."
    local i=0
    ankey.__type_passwd "$1" "$passwd" || {
        ankey.__clear_sensitive_var passwd
        ankey.err "Failed to type the password"
    }
    ankey.__clear_sensitive_var passwd
    ankey.__press_to_continue
}

ankey.action.quit() {
    ankey.__send_cmd "$1" "$2" 'quit'
}

# The main loop
# $1: Options dict name
# $2: Session dict name
ankey.start() {
    local -n _rc="$1" _ss="$2"
    # A state machine, basically
    local action=select_action
    while true; do
        ankey.action.$action "$1" "$2" action || {
            # On error, return to the main menu
            action="select_action"
            ankey.__press_to_continue
        }
        # Save the config on every config action
        [[ $action == type_passwd ]] || ankey.save_config "$1"
        # Break on quit
        [[ $action != quit ]] || break
        # Clear the screen for each action
        printf '\033[2J\033[3J\033[1;1H'
    done
}

# shellcheck disable=SC2034
ankey.main() {
    set -eo pipefail
    ankey.prereq

    # Options dict
    local -A opts=(
        # Options from command line
        [CONFIG_FILE]="$HOME/.config/ankey/ankey.conf" # The config file

        # Options from config file
        [CONFIGS_TO_SAVE]='FZF NONCE OPENSSL_ITERS NONCE_KEY_ALIAS PW_DICT HID_DEVICE'
        [FZF]='fzf'               # The fzf executable
        [NONCE]=''                # The nonce for biometric auth
        [OPENSSL_ITERS]=20000     # The number of iterations for openssl
        [NONCE_KEY_ALIAS]='ankey' # The alias of the key in termux-keystore
        [PW_DICT]='()'            # The list of encrypted passwds (name -> pw)
        [HID_DEVICE]='/dev/hidg0' # The HID device file
    )
    ankey.parse_args opts "$@"

    # Session dict
    local -A sess=(
        [CHOICE]='' # Current fzf choice, for entry selection
        [FZF_OPTS]='
            --ansi --no-bold --border --border-label-pos=4
            --color=gutter:-1 --reverse --bind=left-click:select+accept'
    )
    ankey.load_config opts
    ankey.start opts sess
}

# shellcheck disable=SC2317
return 0 2>/dev/null || ankey.main "$@"
