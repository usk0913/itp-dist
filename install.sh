#!/bin/sh
# itp のプラグインを、暗号化した配布物から Claude Code・Codex（self は Grok・Antigravity・OpenCode も）へ導入する（macOS・Linux 用）。
#
# 仕様は docs/installer/README.md の 1.2〜1.10（self の経路は 1.1・1.5・1.8・1.9）。POSIX sh（dash・macOS の /bin/sh）で動く。
# 外部コマンドは POSIX のものと、curl・tar・openssl・shasum か sha256sum だけを使う。
#   sh install.sh [--edition dist|self] [--with <id>,<id>] [--remove <id>,<id>] [--uninstall]
#                 [--version <tag>] [--help]
#
# パスワードは環境変数 ITP_PASSWORD か端末（/dev/tty。入力の表示を切る）からだけ読む。
# openssl には `-pass env:` で渡し、引数・出力・エラーメッセージには出さない。
# 本体は main() に包み、最後の行で呼ぶ（curl から途中まで読まれたときに、途中の行を実行しないため）。

# 終了コード: 0 成功 / 1 その他 / 2 引数の誤り / 3 前提不足・対象ホスト無し /
#             4 取得・SHA-256・形式の失敗 / 5 復号の失敗 / 6 一部のホストを止めた

DEFAULT_RELEASES_URL="https://github.com/usk0913/itp-dist/releases"
FORMAT_VERSION=1
# 目録に頼らずに必須と分かる id（--remove の検査に使う。配布物の目録が手元に無いため）
REQUIRED_FALLBACK="common"

TMP_ROOT=""
TTY_STATE=""
PARTIAL=0
HOST_OUT=""
HOST_RC=0
MISSING_HOSTS=""
itp_secret=""

edition="dist"
with_set=0
with_ids=""
remove_ids=""
do_uninstall=0
release_tag=""
dist_dir=""
mp_name=""
mp_dir=""
catalog_file=""
present_hosts=""
home_dir=""
oc_dir=""
grok_home=""
grok_config=""
dist_real=""

# ---------------------------------------------------------------- 表示と終了

die() {
    _rc=$1
    shift
    printf 'エラー: %s\n' "$*" >&2
    exit "$_rc"
}

warn() {
    printf '警告: %s\n' "$*" >&2
}

info() {
    printf '%s\n' "$*"
}

usage() {
    cat <<'EOF'
使い方: install.sh [--edition dist|self] [--with <id>,<id>] [--remove <id>,<id>] [--uninstall]
                   [--version <tag>] [--help]

  --edition    系統。既定は dist
  --with       任意の項目の集合を指定する（画面を出さない）。--with "" は任意の項目を選ばない
  --remove     指定した任意の項目の登録を外す（配布物の取得とパスワードは要らない）
  --uninstall  この系統の登録をすべて外して置き先を片付ける（backup/ は残す）
  --version    Releases のタグを固定する。既定は最新
  --help       この説明を表示する

パスワードは環境変数 ITP_PASSWORD か端末から読みます（引数では受け付けません）。
取得先は ITP_RELEASES_URL で変えられます。
EOF
}

# shellcheck disable=SC2329 # trap から間接的に呼ばれる
cleanup() {
    if [ -n "$TTY_STATE" ]; then
        stty "$TTY_STATE" </dev/tty 2>/dev/null
        TTY_STATE=""
    fi
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT"
    fi
}

# ---------------------------------------------------------------- 一覧の部品（空白区切りの id の一覧）

in_list() {
    case " $2 " in
    *" $1 "*) return 0 ;;
    esac
    return 1
}

list_union() {
    _out=""
    for _x in $1 $2; do
        in_list "$_x" "$_out" || _out="$_out $_x"
    done
    printf '%s' "${_out# }"
}

list_minus() {
    _out=""
    for _x in $1; do
        in_list "$_x" "$2" || _out="$_out $_x"
    done
    printf '%s' "${_out# }"
}

# 目録の並びで、指定した id だけを並べる
list_in_catalog_order() {
    _out=""
    for _x in $(catalog_ids); do
        in_list "$_x" "$1" && _out="$_out $_x"
    done
    printf '%s' "${_out# }"
}

check_id_chars() {
    case $1 in
    *[!A-Za-z0-9._\ -]*) die 2 "$2 に使えない文字があります" ;;
    esac
}

# ---------------------------------------------------------------- 引数

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
        --help | -h)
            usage
            exit 0
            ;;
        --password | --password=*)
            die 2 "--password は受け付けません。パスワードは環境変数 ITP_PASSWORD か端末から渡してください"
            ;;
        --edition)
            [ $# -ge 2 ] || die 2 "--edition に値がありません"
            edition=$2
            shift 2
            ;;
        --edition=*)
            edition=${1#--edition=}
            shift
            ;;
        --with)
            [ $# -ge 2 ] || die 2 "--with に値がありません（空にするときは --with \"\"）"
            with_set=1
            with_ids=$(printf '%s' "$2" | tr ',' ' ')
            shift 2
            ;;
        --with=*)
            with_set=1
            with_ids=$(printf '%s' "${1#--with=}" | tr ',' ' ')
            shift
            ;;
        --remove)
            [ $# -ge 2 ] || die 2 "--remove に値がありません"
            remove_ids=$(printf '%s' "$2" | tr ',' ' ')
            shift 2
            ;;
        --remove=*)
            remove_ids=$(printf '%s' "${1#--remove=}" | tr ',' ' ')
            shift
            ;;
        --uninstall)
            do_uninstall=1
            shift
            ;;
        --version)
            [ $# -ge 2 ] || die 2 "--version に値がありません"
            release_tag=$2
            shift 2
            ;;
        --version=*)
            release_tag=${1#--version=}
            shift
            ;;
        *)
            die 2 "不明な引数があります（--help で使い方を表示します）"
            ;;
        esac
    done

    case $edition in
    dist | self) ;;
    *) die 2 "--edition は dist か self です" ;;
    esac
    check_id_chars "$with_ids" "--with"
    check_id_chars "$remove_ids" "--remove"
    case $release_tag in
    *[!A-Za-z0-9._-]*) die 2 "--version のタグに使えない文字があります" ;;
    esac
    if [ "$do_uninstall" -eq 1 ] && { [ -n "$remove_ids" ] || [ "$with_set" -eq 1 ]; }; then
        die 2 "--uninstall は --with・--remove と同時に使えません"
    fi
    if [ -n "$remove_ids" ] && [ "$with_set" -eq 1 ]; then
        die 2 "--remove は --with と同時に使えません"
    fi
}

# ---------------------------------------------------------------- 場所と状態

setup_paths() {
    _base=${XDG_DATA_HOME:-${HOME:-}/.local/share}
    case $_base in
    /*) ;;
    *) die 1 "置き先の元（XDG_DATA_HOME か HOME）が絶対パスではありません" ;;
    esac
    dist_dir="${_base%/}/itp/$edition"
    mp_dir="$dist_dir/marketplace"
    case $edition in
    dist) mp_name="itp-dist" ;;
    self) mp_name="itp-self" ;;
    esac
    home_dir=${HOME:-}
    oc_dir="$home_dir/.config/opencode"
    grok_home=${GROK_HOME:-$home_dir/.grok}
    grok_config="$grok_home/config.toml"
    if [ "$edition" = "self" ]; then
        case $home_dir in
        /*) ;;
        *) die 1 "HOME が絶対パスではありません" ;;
        esac
    fi
    # 置き先の実体のパス（ホストが登録のパスを実体に直す場合の照合用。無ければ何にも一致しない値）
    dist_real=$(cd "$dist_dir" 2>/dev/null && pwd -P)
    [ -n "$dist_real" ] || dist_real="/nonexistent-itp-dist"
}

state_get() {
    [ -f "$dist_dir/state" ] || return 0
    sed -n "s/^$1=//p" "$dist_dir/state" | head -n 1
}

write_state() {
    # 引数: bundle_version selected installed hosts
    mkdir -p "$dist_dir" || die 1 "置き先を作れません: $dist_dir"
    {
        printf 'format=%s\n' "$FORMAT_VERSION"
        printf 'edition=%s\n' "$edition"
        printf 'bundle_version=%s\n' "$1"
        printf 'selected=%s\n' "$2"
        printf 'installed=%s\n' "$3"
        printf 'hosts=%s\n' "$4"
    } >"$dist_dir/state.new" || die 1 "state を書けません"
    mv "$dist_dir/state.new" "$dist_dir/state" || die 1 "state を置けません"
}

# ---------------------------------------------------------------- 目録（タブ区切り。$catalog_file）

catalog_ids() {
    awk -F '\t' '$0 !~ /^#/ && $1 != "" { print $1 }' "$catalog_file"
}

# 引数: id 列番号（1 id・2 label・3 plugin・4 kind・5 prereq・6 prereq_label）
catalog_get() {
    awk -F '\t' -v id="$1" -v col="$2" '$0 !~ /^#/ && $1 == id { print $col; exit }' "$catalog_file"
}

catalog_has() {
    [ -n "$(catalog_get "$1" 1)" ]
}

plugin_of() {
    _p=""
    [ -f "$catalog_file" ] && _p=$(catalog_get "$1" 3)
    [ -n "$_p" ] || _p="itp-$1"
    printf '%s' "$_p"
}

# ---------------------------------------------------------------- ホスト

host_label() {
    case $1 in
    claude) printf 'Claude Code' ;;
    codex) printf 'Codex' ;;
    grok) printf 'Grok' ;;
    agy) printf 'Antigravity' ;;
    opencode) printf 'OpenCode' ;;
    *) printf '%s' "$1" ;;
    esac
}

detect_hosts() {
    present_hosts=""
    _clis="claude codex"
    [ "$edition" = "self" ] && _clis="claude codex grok agy"
    for _h in $_clis; do
        command -v "$_h" >/dev/null 2>&1 && present_hosts="$present_hosts $_h"
    done
    # OpenCode は CLI ではなく、設定のフォルダがあるときだけ対象にする
    if [ "$edition" = "self" ] && [ -d "$oc_dir" ]; then
        present_hosts="$present_hosts opencode"
    fi
    present_hosts=${present_hosts# }
}

# 登録の CLI を実行し、出力と終了コードを HOST_OUT・HOST_RC に残す（端末の入力は渡さない）
host_run() {
    HOST_OUT=$("$@" 2>&1 </dev/null)
    HOST_RC=$?
}

sandbox_hit() {
    printf '%s\n' "$1" | grep -qiE 'sandbox initialization failed|operation not permitted'
}

report_failure() {
    _host=$1
    shift
    warn "$(host_label "$_host") を止めました。失敗したコマンド: $* （終了コード $HOST_RC）"
    if [ -n "$HOST_OUT" ]; then
        printf '%s\n' "$HOST_OUT" | sed 's/^/    /' >&2
    fi
    if sandbox_hit "$HOST_OUT"; then
        warn "ホストのサンドボックスの中では実行できません。通常の端末から、もう一度実行してください"
    fi
    PARTIAL=1
}

# 引数: ホスト名 コマンド…（ホスト名はそのまま CLI 名）。失敗したら報告して 1 を返す
host_step() {
    host_run "$@"
    [ "$HOST_RC" -eq 0 ] && return 0
    report_failure "$@"
    return 1
}

# 標準入力の JSON を、`"キー": "値"` の値だけの行にする（空白・改行の量に依らない）
# shellcheck disable=SC2020 # 同じ文字（改行）を並べて、各区切りを1文字ずつ改行にする
json_values_stdin() {
    tr ',{}[]' '\n\n\n\n\n' | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

# 引数: キー ファイル
json_values() {
    json_values_stdin "$1" <"$2"
}

# 引数: ホスト名。保存した plugin list の中の `名前@marketplace` を1行ずつ出す
host_list_ids() {
    case $1 in
    claude) json_values id "$TMP_ROOT/list.claude" ;;
    codex) json_values pluginId "$TMP_ROOT/list.codex" ;;
    esac
}

# shellcheck disable=SC2020 # json_values と同じ
host_marketplace_present() {
    case $1 in
    claude)
        host_run claude plugin marketplace list --json
        [ "$HOST_RC" -eq 0 ] || return 1
        printf '%s\n' "$HOST_OUT" | tr ',{}[]' '\n\n\n\n\n' |
            grep -qE "\"name\"[[:space:]]*:[[:space:]]*\"$mp_name\""
        ;;
    codex)
        host_run codex plugin marketplace list
        [ "$HOST_RC" -eq 0 ] || return 1
        printf '%s\n' "$HOST_OUT" |
            grep -qE "(^|[^A-Za-z0-9._-])$mp_name([^A-Za-z0-9._-]|\$)"
        ;;
    esac
}

# 外す前に、そのホストに登録があるかを確かめる（無ければ外す操作を呼ばない）。
# 引数: ホスト名 プラグイン名。0 は登録あり（か、list が失敗して確かめられない）、1 は登録なし
host_plugin_registered() {
    case $1 in
    claude)
        host_run claude plugin list --json
        _key=id
        ;;
    codex)
        host_run codex plugin list --json
        _key=pluginId
        ;;
    grok)
        # 置き先の中を指す登録（自分が入れたもの）だけを、登録ありとする。別の出所の同名は外さない
        [ -n "$(grok_own_paths "$2")" ]
        return
        ;;
    agy)
        # state に自分の記録があるときだけ、登録ありとする。別の出所の同名は外さない
        plugin_is_ours_on agy "$2" || return 1
        [ -e "$home_dir/.gemini/config/plugins/$2" ] ||
            [ -e "$home_dir/.gemini/antigravity-cli/plugins/$2" ]
        return
        ;;
    *) return 0 ;;
    esac
    [ "$HOST_RC" -eq 0 ] || return 0
    printf '%s\n' "$HOST_OUT" | json_values_stdin "$_key" | grep -qxF "$2@$mp_name"
}

# 引数: ホスト名。0 は marketplace の登録あり（か、list が失敗して確かめられない）、1 は登録なし
host_marketplace_registered() {
    host_marketplace_present "$1" && return 0
    [ "$HOST_RC" -ne 0 ]
}

host_remove_plugin() {
    host_plugin_registered "$1" "$2" || return 0
    case $1 in
    claude) host_step claude plugin uninstall "$2@$mp_name" --scope user ;;
    codex) host_step codex plugin remove "$2@$mp_name" ;;
    grok) host_step grok plugin uninstall "$2" --keep-data ;;
    agy) host_step agy plugin uninstall "$2" ;;
    opencode) return 0 ;; # OpenCode はプラグイン単位ではなく、写したファイルの単位（opencode_remove_files）
    esac
}

host_remove_marketplace() {
    case $1 in
    claude | codex)
        host_marketplace_registered "$1" || return 0
        host_step "$1" plugin marketplace remove "$mp_name"
        ;;
    *) return 0 ;;
    esac
}

# ---------------------------------------------------------------- 前提・パスワード

sha256_of() {
    case $SHA_TOOL in
    sha256sum) sha256sum "$1" 2>/dev/null ;;
    shasum) shasum -a 256 "$1" 2>/dev/null ;;
    esac | awk '{ print $1; exit }'
}

find_sha_tool() {
    SHA_TOOL=""
    if command -v sha256sum >/dev/null 2>&1; then
        SHA_TOOL=sha256sum
    elif command -v shasum >/dev/null 2>&1; then
        SHA_TOOL=shasum
    fi
}

check_prereqs() {
    _missing=""
    for _c in curl tar openssl; do
        command -v "$_c" >/dev/null 2>&1 || _missing="$_missing $_c"
    done
    find_sha_tool
    [ -n "$SHA_TOOL" ] || _missing="$_missing sha256sum（または shasum）"
    [ -z "$_missing" ] || die 3 "前提のコマンドが足りません:$_missing"
    # openssl が enc -pbkdf2 を使えること（パスワードの代わりの試験値は、この呼び出しだけの環境変数で渡す）
    if ! printf 'x' | ITP_INSTALL_PROBE=x openssl enc -aes-256-cbc -pbkdf2 -md sha256 -iter 1000 -salt \
        -pass env:ITP_INSTALL_PROBE >/dev/null 2>&1; then
        die 3 "openssl が enc -pbkdf2 を使えません（OpenSSL 1.1.1 以降か LibreSSL が要ります）"
    fi
}

have_tty() {
    ( : </dev/tty ) 2>/dev/null
}

read_password() {
    if [ -z "$itp_secret" ]; then
        have_tty || die 5 "パスワードがありません。環境変数 ITP_PASSWORD に入れるか、端末から実行してください"
        printf 'パスワード: ' >/dev/tty
        TTY_STATE=$(stty -g </dev/tty)
        stty -echo </dev/tty
        IFS= read -r itp_secret </dev/tty
        stty "$TTY_STATE" </dev/tty
        TTY_STATE=""
        printf '\n' >/dev/tty
    fi
    [ -n "$itp_secret" ] || die 5 "パスワードが空です"
}

# ---------------------------------------------------------------- 取得・検証・展開

fetch_bundle() {
    _base=${ITP_RELEASES_URL:-$DEFAULT_RELEASES_URL}
    _base=${_base%/}
    if [ -n "$release_tag" ]; then
        _url="$_base/download/$release_tag"
    else
        _url="$_base/latest/download"
    fi
    enc_name="itp-$edition.tar.gz.enc"
    enc_file="$TMP_ROOT/$enc_name"
    info "配布物を取得しています: $_url"
    curl -fsSL --connect-timeout 30 -o "$enc_file" "$_url/$enc_name" 2>/dev/null ||
        die 4 "配布物を取得できません: $_url/$enc_name"
    curl -fsSL --connect-timeout 30 -o "$enc_file.sha256" "$_url/$enc_name.sha256" 2>/dev/null ||
        die 4 "SHA-256 のファイルを取得できません: $_url/$enc_name.sha256"
}

verify_download() {
    _expected=""
    read -r _expected _ <"$enc_file.sha256"
    case $_expected in
    *[!0-9a-f]* | "") die 4 "SHA-256 のファイルの形が正しくありません" ;;
    esac
    [ "${#_expected}" -eq 64 ] || die 4 "SHA-256 のファイルの形が正しくありません"
    _actual=$(sha256_of "$enc_file")
    [ "$_actual" = "$_expected" ] || die 4 "配布物の SHA-256 が一致しません"
}

decrypt_bundle() {
    tar_file="$TMP_ROOT/bundle.tar.gz"
    # パスワードは、この呼び出しだけの環境変数で渡す（引数・export には載せない）
    ITP_INSTALL_OPENSSL_PW=$itp_secret openssl enc -d -aes-256-cbc -pbkdf2 -md sha256 -iter 600000 \
        -pass env:ITP_INSTALL_OPENSSL_PW -in "$enc_file" -out "$tar_file" 2>/dev/null
    _rc=$?
    itp_secret=""
    [ "$_rc" -eq 0 ] || die 5 "復号できません（パスワードが違う可能性があります）"
    tar -tzf "$tar_file" >"$TMP_ROOT/tar.list" 2>/dev/null ||
        die 5 "復号できません（パスワードが違う可能性があります）"
}

extract_bundle() {
    if grep -qE '(^/|(^|/)\.\.(/|$))' "$TMP_ROOT/tar.list"; then
        die 4 "配布物に危険なパスが含まれています"
    fi
    # 項目の種別を、展開の前に確かめる。`tar -tv` の各行の先頭の1文字が種別（GNU tar・bsdtar とも
    # - は通常のファイル、d はフォルダ、l はシンボリックリンク、h はハードリンク、p・c・b は特殊ファイル）。
    # 通常のファイルとフォルダ以外は拒む
    tar -tvzf "$tar_file" 2>/dev/null |
        awk '$0 != "" { t = substr($0, 1, 1); if (t != "-" && t != "d") bad = 1 } END { exit bad }' ||
        die 4 "配布物に通常のファイルとフォルダ以外が含まれています"
    stage="$TMP_ROOT/stage"
    mkdir "$stage" || die 1 "作業フォルダを作れません"
    tar -xzf "$tar_file" -C "$stage" 2>/dev/null || die 4 "配布物を展開できません"
    bundle="$stage/itp-bundle"
    [ -d "$bundle" ] || die 4 "配布物に itp-bundle/ がありません"
    if [ -n "$(find "$bundle" -type l)" ]; then
        die 4 "配布物にシンボリックリンクが含まれています"
    fi
}

# bundle の中で SHA256SUMS の全行を照合し、載っていないファイルが無いことも確かめる
verify_sums_in_bundle() {
    [ -f SHA256SUMS ] || {
        printf 'SHA256SUMS がありません\n' >&2
        return 1
    }
    _dups=$(sed 's/^[^ ]*  //' SHA256SUMS | sort | uniq -d)
    [ -z "$_dups" ] || {
        printf 'SHA256SUMS に同じパスの行があります\n' >&2
        return 1
    }
    _n=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        _digest=${_line%%  *}
        _path=${_line#*  }
        case $_path in
        /* | ../* | */../* | */.. | .. | "" | ./* | */./* | *//* | */. | .)
            printf 'SHA256SUMS のパスが正しくありません\n' >&2
            return 1
            ;;
        esac
        [ "${#_digest}" -eq 64 ] || return 1
        [ -f "$_path" ] || return 1
        [ "$(sha256_of "./$_path")" = "$_digest" ] || {
            printf '%s の SHA-256 が一致しません\n' "$_path" >&2
            return 1
        }
        _n=$((_n + 1))
    done <SHA256SUMS
    _files=$(find . -type f | wc -l | tr -d ' ')
    [ "$_files" -eq $((_n + 1)) ] || {
        printf 'SHA256SUMS に載っていないファイルがあります\n' >&2
        return 1
    }
}

bundle_kv() {
    awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$bundle/BUNDLE.txt"
}

verify_bundle() {
    ( cd "$bundle" && verify_sums_in_bundle ) || die 4 "配布物の中身の SHA-256 の照合に失敗しました"
    [ "$(bundle_kv format_version)" = "$FORMAT_VERSION" ] ||
        die 4 "対応しない形式の配布物です（format_version=$(bundle_kv format_version)）"
    [ "$(bundle_kv edition)" = "$edition" ] || die 4 "配布物の系統が違います"
    [ "$(bundle_kv marketplace)" = "$mp_name" ] || die 4 "配布物の marketplace の名前が違います"
    bundle_version=$(bundle_kv bundle_version)
    catalog_file="$bundle/catalog.tsv"
    [ -f "$catalog_file" ] || die 4 "配布物に目録がありません"
    [ -d "$bundle/marketplace" ] || die 4 "配布物に marketplace/ がありません"
}

# ---------------------------------------------------------------- 選択

screen_select() {
    # 引数: 初期の選択（任意の項目の id）。選んだ集合を sel_opt に入れる。q で終了コード0
    sel_opt=$1
    while :; do
        {
            printf '\n導入する項目を選んでください。\n'
            for _id in $cat_req; do
                printf '  [x] %s（必須）\n' "$(catalog_get "$_id" 2)"
            done
            _n=0
            for _id in $cat_opt; do
                _n=$((_n + 1))
                _mark=" "
                in_list "$_id" "$sel_opt" && _mark="x"
                printf '  [%s] %s) %s\n' "$_mark" "$_n" "$(catalog_get "$_id" 2)"
            done
            printf '番号で切り替え、空の行で決定、q で中止: '
        } >/dev/tty
        IFS= read -r _line </dev/tty || {
            printf '\n' >/dev/tty
            die 1 "端末の入力が閉じました"
        }
        case $_line in
        q | Q)
            info "中止しました。何も変更していません"
            exit 0
            ;;
        "") return 0 ;;
        *[!0-9]*)
            printf '番号か q を入力してください\n' >/dev/tty
            continue
            ;;
        esac
        _n=0
        _hit=""
        for _id in $cat_opt; do
            _n=$((_n + 1))
            [ "$_n" -eq "$_line" ] && _hit=$_id
        done
        if [ -z "$_hit" ]; then
            printf '範囲外の番号です\n' >/dev/tty
        elif in_list "$_hit" "$sel_opt"; then
            sel_opt=$(list_minus "$sel_opt" "$_hit")
        else
            sel_opt=$(list_union "$sel_opt" "$_hit")
        fi
    done
}

choose_selection() {
    cat_req=""
    cat_opt=""
    for _id in $(catalog_ids); do
        if [ "$(catalog_get "$_id" 4)" = "required" ]; then
            cat_req="$cat_req $_id"
        else
            cat_opt="$cat_opt $_id"
        fi
    done
    cat_req=${cat_req# }
    cat_opt=${cat_opt# }

    prior=""
    for _id in $(state_get selected); do
        catalog_has "$_id" && prior="$prior $_id"
    done
    prior=$(list_minus "$prior" "$cat_req")

    if [ "$with_set" -eq 1 ]; then
        for _id in $with_ids; do
            catalog_has "$_id" || die 2 "目録に無い id です: $_id"
        done
        sel_opt=$(list_minus "$with_ids" "$cat_req")
    elif have_tty; then
        screen_select "$prior"
    else
        sel_opt=$prior
    fi
    sel_ids=$(list_in_catalog_order "$(list_union "$cat_req" "$sel_opt")")
    sel_plugins=""
    for _id in $sel_ids; do
        _p=$(catalog_get "$_id" 3)
        [ -d "$bundle/marketplace/plugins/$_p" ] || die 4 "配布物にプラグインがありません: $_p"
        sel_plugins="$sel_plugins $_p"
    done
    sel_plugins=${sel_plugins# }
}

warn_prereqs() {
    for _id in $sel_ids; do
        _cmd=$(catalog_get "$_id" 5)
        [ -n "$_cmd" ] && [ "$_cmd" != "-" ] || continue
        if ! command -v "$_cmd" >/dev/null 2>&1; then
            warn "$(catalog_get "$_id" 2) の前提 $(catalog_get "$_id" 6)（コマンド $_cmd）が PATH に見つかりません。登録は続けます"
        fi
    done
}

# ---------------------------------------------------------------- 登録

# Grok の config.toml の [plugins] の enabled = [...]（1行）に、選んだプラグインを足す。
# 足すものが無ければ何も変えない。変えるときは、変える前の写しを <置き先>/backup/ に取る。
grok_enable_plugins() {
    _new="$TMP_ROOT/grok-config.new"
    awk -v names="$sel_plugins" '
        BEGIN { n = split(names, nm, " ") }
        /^\[/ { insec = ($0 ~ /^\[plugins\][ \t]*$/) }
        insec && !done && /^enabled[ \t]*=[ \t]*\[.*\][ \t]*$/ {
            line = $0
            sub(/[ \t]*\][ \t]*$/, "", line)
            body = line
            sub(/^enabled[ \t]*=[ \t]*\[/, "", body)
            empty = (body ~ /^[ \t]*$/)
            for (i = 1; i <= n; i++) {
                if (index($0, "\"" nm[i] "\"") == 0) {
                    line = line (empty ? "" : ", ") "\"" nm[i] "\""
                    empty = 0
                }
            }
            print line "]"
            done = 1
            next
        }
        { print }
    ' "$grok_config" >"$_new" || {
        warn "Grok の config.toml を作り直せません"
        PARTIAL=1
        return 1
    }
    cmp -s "$_new" "$grok_config" && return 0
    mkdir -p "$dist_dir/backup" || die 1 "backup/ を作れません"
    _stamp=$(date +%Y%m%d-%H%M%S)
    _copy="$dist_dir/backup/grok-config-$_stamp.toml"
    _i=1
    while [ -e "$_copy" ]; do
        _copy="$dist_dir/backup/grok-config-$_stamp-$_i.toml"
        _i=$((_i + 1))
    done
    cp "$grok_config" "$_copy" || die 1 "Grok の config.toml の写しを取れません"
    cp "$_new" "$grok_config" || {
        warn "Grok の config.toml を書き換えられません（写し: $_copy）"
        PARTIAL=1
        return 1
    }
    info "Grok の config.toml の plugins.enabled に足しました（元の写し: $_copy）"
}

# 配布物の opencode/ のファイルを ~/.config/opencode/ の下へ写し、写し終えてから opencode-files に一覧と SHA-256 を記録する。
# 途中で失敗したときは、そこまでに写せたファイルだけを記録する（記録に載るのは、実在するファイルだけ）。
# 前の版の記録のうち、今の配布物に無いファイルの記録は残す（自分が写したファイルとして、外すときに消す）
opencode_register() {
    [ -d "$bundle/opencode" ] || return 0
    _list="$TMP_ROOT/opencode-files.list"
    _done="$TMP_ROOT/opencode-files.done"
    opencode_bundle_list >"$_list"
    : >"$_done"
    _copy_ok=1
    while IFS= read -r _line; do
        _rel=${_line#*  }
        _dest="$oc_dir/$_rel"
        if ! mkdir -p "$(dirname "$_dest")" || ! cp "$bundle/opencode/$_rel" "$_dest"; then
            warn "$(host_label opencode) を止めました。ファイルを写せません: $_dest"
            PARTIAL=1
            _copy_ok=0
            break
        fi
        printf '%s\n' "$_line" >>"$_done"
    done <"$_list"
    if [ -s "$_done" ] || [ -f "$dist_dir/opencode-files" ]; then
        mkdir -p "$dist_dir" || die 1 "置き先を作れません: $dist_dir"
        {
            cat "$_done"
            if [ -f "$dist_dir/opencode-files" ]; then
                awk 'NR == FNR { p = $0; sub(/^[0-9a-f]+  /, "", p); seen[p] = 1; next }
                    { p = $0; sub(/^[0-9a-f]+  /, "", p); if (!(p in seen)) print }' \
                    "$_done" "$dist_dir/opencode-files"
            fi
        } >"$dist_dir/opencode-files.new" || die 1 "opencode-files を書けません"
        mv "$dist_dir/opencode-files.new" "$dist_dir/opencode-files" || die 1 "opencode-files を置けません"
    fi
    [ "$_copy_ok" -eq 1 ]
}

# opencode-files に記録した自分のファイルだけを消す（中身が記録と違うファイルは、書き換えられているので残す）
opencode_remove_files() {
    [ -f "$dist_dir/opencode-files" ] || return 0
    while IFS= read -r _line; do
        _digest=${_line%%  *}
        _rel=${_line#*  }
        _f="$oc_dir/$_rel"
        [ -f "$_f" ] || continue
        if [ "$(sha256_of "$_f")" = "$_digest" ]; then
            rm -f "$_f"
            # 空になったフォルダは消すが、~/.config/opencode/ の直下のフォルダ（skills など）は消さない
            _d=$(dirname "$_f")
            while [ "$_d" != "$oc_dir" ] && [ "$(dirname "$_d")" != "$oc_dir" ] && rmdir "$_d" 2>/dev/null; do
                _d=$(dirname "$_d")
            done
        else
            warn "$(host_label opencode): 写した後に書き換えられているので残しました: $_f"
        fi
    done <"$dist_dir/opencode-files"
}


# 自分が（この置き先から）入れたプラグインか。state の hosts に引数のホストがあり、installed にそのプラグインがある
plugin_is_ours_on() {
    # 引数: ホスト名 プラグイン名
    in_list "$1" "$(state_get hosts)" || return 1
    for _oid in $(state_get installed); do
        [ "$(plugin_of "$_oid")" = "$2" ] && return 0
    done
    return 1
}

# Grok の registry.json の source_path のうち、…/plugins/<名前> で終わるもの
grok_paths_of() {
    _reg="$grok_home/installed-plugins/registry.json"
    [ -f "$_reg" ] || return 0
    json_values source_path "$_reg" | while IFS= read -r _sp; do
        case $_sp in
        */plugins/"$1") printf '%s\n' "$_sp" ;;
        esac
    done
}

# 上のうち、置き先の中のもの（自分が入れたもの）
grok_own_paths() {
    grok_paths_of "$1" | while IFS= read -r _sp; do
        case $_sp in
        "$dist_dir"/* | "$dist_real"/*) printf '%s\n' "$_sp" ;;
        esac
    done
}

# 上のうち、置き先の外のもの（別の出所）
grok_foreign_paths() {
    grok_paths_of "$1" | while IFS= read -r _sp; do
        case $_sp in
        "$dist_dir"/* | "$dist_real"/*) ;;
        *) printf '%s\n' "$_sp" ;;
        esac
    done
}

# Grok の config.toml が「[plugins] の節の中の1行の enabled = [...]」を1つだけ持つ形か
grok_config_shape_ok() {
    [ -f "$grok_config" ] || return 1
    _shape=$(awk '
        /^\[/ { insec = ($0 ~ /^\[plugins\][ \t]*$/); if (insec) secs++; next }
        insec && /^enabled[ \t]*=/ {
            tot++
            if ($0 ~ /^enabled[ \t]*=[ \t]*\[.*\][ \t]*$/) one++
        }
        END { if (secs == 1 && tot == 1 && one == 1) print "ok" }
    ' "$grok_config")
    [ "$_shape" = "ok" ]
}

# 配布物の opencode/ のファイルの一覧（`<SHA-256>  <相対パス>`。opencode-files と同じ形）
opencode_bundle_list() {
    sed -n 's|^\([0-9a-f]\{64\}\)  opencode/|\1  |p' "$bundle/SHA256SUMS"
}

# 写す先に既にあるファイルのうち、自分が写したもの（opencode-files に記録があり中身が同じ）ではないもの
opencode_foreign_files() {
    [ -d "$bundle/opencode" ] || return 0
    opencode_bundle_list | while IFS= read -r _line; do
        _rel=${_line#*  }
        _f="$oc_dir/$_rel"
        if [ -L "$_f" ]; then
            printf '%s\n' "$_f"
            continue
        fi
        [ -e "$_f" ] || continue
        _rec=""
        if [ -f "$dist_dir/opencode-files" ]; then
            _rec=$(awk -v p="$_rel" '{ s = $0; sub(/^[0-9a-f]+  /, "", s); if (s == p) { print substr($0, 1, 64); exit } }' \
                "$dist_dir/opencode-files")
        fi
        if [ -z "$_rec" ] || [ "$_rec" != "$(sha256_of "$_f")" ]; then
            printf '%s\n' "$_f"
        fi
    done
}

stop_host_for_duplicates() {
    # 引数: ホスト名 見つかったもの（改行区切り） 外す手順の説明
    warn "$(host_label "$1") を止めました。別の出所の同名のプラグインかファイルがあります:"
    printf '%s\n' "$2" | sed 's/^/    /' >&2
    warn "$3"
    warn "外してから、もう一度実行してください"
    PARTIAL=1
}

# 別の出所の同名プラグインがあれば、そのホストを止める（止めたホストには何も変更しない）。0 なら登録してよい
check_host() {
    _host=$1
    _dup=""
    case $_host in
    claude | codex)
        if [ "$_host" = "claude" ]; then
            host_run claude plugin list --json
        else
            host_run codex plugin list --json
        fi
        printf '%s\n' "$HOST_OUT" >"$TMP_ROOT/list.$_host"
        if [ "$HOST_RC" -ne 0 ]; then
            report_failure "$_host" "$_host plugin list --json"
            return 1
        fi
        for _p in $sel_plugins; do
            _found=$(host_list_ids "$_host" | grep -E "^$_p@" | grep -vxF "$_p@$mp_name")
            [ -n "$_found" ] && _dup="$_dup $_found"
        done
        if [ -n "$_dup" ]; then
            warn "$(host_label "$_host") を止めました。別の出所の同名のプラグインが入っています:$_dup"
            for _d in $_dup; do
                case $_host in
                claude) warn "  外すには: claude plugin uninstall $_d --scope user" ;;
                codex) warn "  外すには: codex plugin remove $_d" ;;
                esac
            done
            warn "外してから、もう一度実行してください"
            PARTIAL=1
            return 1
        fi
        ;;
    grok)
        if ! grok_config_shape_ok; then
            warn "Grok を止めました。$grok_config が、[plugins] の節の中の1行の enabled = [...] を持つ形ではありません（ファイルが無い場合を含みます）"
            warn "  手順: config.toml の [plugins] の節に enabled = [\"itp-common\"] のように1行で書いてから、もう一度実行してください"
            PARTIAL=1
            return 1
        fi
        for _p in $sel_plugins; do
            _found=$(grok_foreign_paths "$_p")
            [ -n "$_found" ] && _dup="$_dup$_found
"
        done
        if [ -n "$_dup" ]; then
            stop_host_for_duplicates grok "${_dup%?}" "  外すには: grok plugin uninstall <名前> --keep-data"
            return 1
        fi
        ;;
    agy)
        for _p in $sel_plugins; do
            plugin_is_ours_on agy "$_p" && continue
            for _d in "$home_dir/.gemini/config/plugins/$_p" "$home_dir/.gemini/antigravity-cli/plugins/$_p"; do
                [ -e "$_d" ] && _dup="$_dup$_d
"
            done
        done
        if [ -n "$_dup" ]; then
            stop_host_for_duplicates agy "${_dup%?}" "  外すには: agy plugin uninstall <名前>（か、そのフォルダを別の場所へ移す）"
            return 1
        fi
        ;;
    opencode)
        _dup=$(opencode_foreign_files)
        if [ -n "$_dup" ]; then
            stop_host_for_duplicates opencode "$_dup" "  このファイルを別の場所へ移すか消してください（自分が写したファイルではありません）"
            return 1
        fi
        ;;
    esac
    return 0
}

detect_duplicates() {
    active_hosts=""
    for _h in $present_hosts; do
        check_host "$_h" && active_hosts="$active_hosts $_h"
    done
    active_hosts=${active_hosts# }
}

# marketplace.new/ に写して今の marketplace/ と入れ替える（今の版は backup/<時刻>/ へ移す）
replace_marketplace() {
    mkdir -p "$dist_dir" || die 1 "置き先を作れません: $dist_dir"
    rm -rf "$dist_dir/marketplace.new"
    mkdir "$dist_dir/marketplace.new" || die 1 "置き先を作れません"
    cp -R "$bundle/marketplace/." "$dist_dir/marketplace.new/" || {
        rm -rf "$dist_dir/marketplace.new"
        die 1 "配布物を置き先へ写せません"
    }
    cp "$catalog_file" "$dist_dir/catalog.tsv" || die 1 "目録を置き先へ写せません"
    _backup=""
    if [ -d "$mp_dir" ]; then
        mkdir -p "$dist_dir/backup" || die 1 "backup/ を作れません"
        _stamp=$(date +%Y%m%d-%H%M%S)
        _backup="$dist_dir/backup/$_stamp"
        _i=1
        while [ -e "$_backup" ]; do
            _backup="$dist_dir/backup/$_stamp-$_i"
            _i=$((_i + 1))
        done
        mv "$mp_dir" "$_backup" || die 1 "前の版を backup/ へ移せません"
    fi
    if ! mv "$dist_dir/marketplace.new" "$mp_dir"; then
        [ -n "$_backup" ] && mv "$_backup" "$mp_dir"
        die 1 "新しい版を置けません"
    fi
    if [ -n "$_backup" ]; then
        info "前の版を保全しました: $_backup"
    fi
}

register_host() {
    _host=$1
    case $_host in
    claude)
        if host_marketplace_present claude; then
            host_step claude plugin marketplace update "$mp_name" || return 1
        else
            host_step claude plugin marketplace add "$mp_dir" --scope user || return 1
        fi
        for _p in $sel_plugins; do
            if host_list_ids claude | grep -qxF "$_p@$mp_name"; then
                host_step claude plugin uninstall "$_p@$mp_name" --scope user || return 1
            fi
            host_step claude plugin install "$_p@$mp_name" --scope user || return 1
        done
        ;;
    codex)
        if ! host_marketplace_present codex; then
            host_step codex plugin marketplace add "$mp_dir" || return 1
        fi
        for _p in $sel_plugins; do
            host_step codex plugin add "$_p@$mp_name" || return 1
        done
        ;;
    grok)
        for _p in $sel_plugins; do
            if [ -n "$(grok_paths_of "$_p")" ]; then
                host_step grok plugin uninstall "$_p" --keep-data || return 1
            fi
            host_step grok plugin install "$mp_dir/plugins/$_p" --trust || return 1
        done
        grok_enable_plugins || return 1
        ;;
    agy)
        for _p in $sel_plugins; do
            host_step agy plugin validate "$mp_dir/plugins/$_p" || return 1
            if [ -e "$home_dir/.gemini/config/plugins/$_p" ] ||
                [ -e "$home_dir/.gemini/antigravity-cli/plugins/$_p" ]; then
                host_step agy plugin uninstall "$_p" || return 1
            fi
            host_step agy plugin install "$mp_dir/plugins/$_p" || return 1
            host_step agy plugin enable "$_p" || return 1
        done
        ;;
    opencode)
        opencode_register || return 1
        ;;
    esac
    info "$(host_label "$_host"): 登録しました（$sel_plugins）"
}

# ---------------------------------------------------------------- 外す

# state の hosts のうち、いま CLI があるものを hosts に入れる。CLI が無いホストは、登録を外せないので
# MISSING_HOSTS に入れ、PARTIAL にする（呼び出し側は、片付け・state の更新をしない）
state_hosts_present() {
    hosts=""
    MISSING_HOSTS=""
    for _host in $(state_get hosts); do
        if in_list "$_host" "$present_hosts"; then
            hosts="$hosts $_host"
        elif [ "$_host" = "opencode" ]; then
            :  # OpenCode の写したファイルは opencode-files から外す（フォルダの有無に依らない）
        else
            warn "$(host_label "$_host") の CLI が見つかりません。登録は外せませんでした"
            MISSING_HOSTS="$MISSING_HOSTS $_host"
            PARTIAL=1
        fi
    done
    hosts=${hosts# }
}

do_remove() {
    catalog_file="$dist_dir/catalog.tsv"
    required="$REQUIRED_FALLBACK"
    if [ -f "$catalog_file" ]; then
        for _id in $(catalog_ids); do
            [ "$(catalog_get "$_id" 4)" = "required" ] && required="$required $_id"
        done
    fi
    for _id in $remove_ids; do
        in_list "$_id" "$required" && die 2 "必須の項目は外せません: $_id"
        if [ -f "$catalog_file" ] && ! catalog_has "$_id"; then
            die 2 "目録に無い id です: $_id"
        fi
    done

    detect_hosts
    installed=$(state_get installed)
    state_hosts_present
    removed=""
    for _id in $remove_ids; do
        if ! in_list "$_id" "$installed"; then
            info "入っていません: $_id"
            continue
        fi
        _plugin=$(plugin_of "$_id")
        _failed=0
        [ -z "$MISSING_HOSTS" ] || _failed=1
        for _host in $hosts; do
            host_remove_plugin "$_host" "$_plugin" || _failed=1
        done
        if [ "$_failed" -eq 0 ]; then
            removed="$removed $_id"
            info "外しました: $_id"
        else
            warn "外せなかったので、state には残しました: $_id"
        fi
    done
    removed=${removed# }
    if [ -f "$dist_dir/state" ] && [ -n "$removed" ]; then
        write_state "$(state_get bundle_version)" \
            "$(list_minus "$(state_get selected)" "$removed")" \
            "$(list_minus "$installed" "$removed")" \
            "$(state_get hosts)"
    fi
}

do_uninstall_all() {
    catalog_file="$dist_dir/catalog.tsv"
    detect_hosts
    installed=$(state_get installed)
    state_hosts_present
    for _host in $hosts; do
        for _id in $installed; do
            host_remove_plugin "$_host" "$(plugin_of "$_id")" || true
        done
        host_remove_marketplace "$_host" || true
    done
    if [ "$edition" = "self" ]; then
        find_sha_tool
        [ -n "$SHA_TOOL" ] || die 3 "前提のコマンドが足りません: sha256sum（または shasum）"
        opencode_remove_files
    fi
    if [ "$PARTIAL" -ne 0 ]; then
        warn "外せなかった登録があるので、置き先は片付けませんでした。原因を直して、もう一度実行してください"
        return 0
    fi
    rm -rf "$dist_dir/marketplace" "$dist_dir/marketplace.new" "$dist_dir/state" \
        "$dist_dir/state.new" "$dist_dir/catalog.tsv" "$dist_dir/opencode-files"
    info "登録を外し、置き先を片付けました（backup/ は残しています）: $dist_dir"
}

# ---------------------------------------------------------------- 導入

do_install() {
    check_prereqs
    detect_hosts
    [ -n "$present_hosts" ] || die 3 "対象のホスト（claude・codex。self は grok・agy・OpenCode も）が見つかりません"
    read_password

    TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/itp-install.XXXXXX") || die 1 "作業用の一時フォルダを作れません"
    fetch_bundle
    verify_download
    decrypt_bundle
    extract_bundle
    verify_bundle
    choose_selection
    warn_prereqs

    detect_duplicates
    [ -n "$active_hosts" ] || {
        warn "登録できるホストが無いので、何も変更しませんでした"
        exit 6
    }

    replace_marketplace
    ok_hosts=""
    for _host in $active_hosts; do
        register_host "$_host" && ok_hosts="$ok_hosts $_host"
    done
    ok_hosts=${ok_hosts# }

    if [ -n "$ok_hosts" ]; then
        # 前回までに登録したホストは、今回の登録に失敗・停止しても残す。OpenCode は opencode-files で
        # 管理するので、今回対象にしたのに登録できなかったときは残さない
        old_hosts=$(state_get hosts)
        in_list opencode "$present_hosts" && old_hosts=$(list_minus "$old_hosts" opencode)
        write_state "$bundle_version" "$sel_ids" \
            "$(list_in_catalog_order "$(list_union "$(state_get installed)" "$sel_ids")")" \
            "$(list_union "$ok_hosts" "$old_hosts")"
        info "導入が終わりました（版 $bundle_version）。Claude Code・Codex は新しいセッションから使えます"
    fi

    _later=""
    _have=$(list_union "$(state_get installed)" "$sel_ids")
    for _id in $cat_opt; do
        in_list "$_id" "$_have" || _later="$_later $(catalog_get "$_id" 2)（--with $_id）"
    done
    if [ -n "$_later" ]; then
        info "任意の項目:$_later は、必要になったら --with を付けて、もう一度実行すると追加できます"
    fi
}

main() {
    umask 022
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    # パスワードは最初にシェル変数へ移し、環境変数は消す（どの経路でも、子プロセスに渡さない）
    itp_secret=${ITP_PASSWORD-}
    unset ITP_PASSWORD

    parse_args "$@"
    setup_paths

    if [ "$do_uninstall" -eq 1 ]; then
        do_uninstall_all
    elif [ -n "$remove_ids" ]; then
        do_remove
    else
        do_install
    fi

    if [ "$PARTIAL" -ne 0 ]; then
        exit 6
    fi
    exit 0
}

main "$@"
