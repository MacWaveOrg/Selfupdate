#!/bin/bash

# MacWave update commands — 4.4.1
#
# 这个文件由 MacWave 仓库的 scripts/build_update_commands.py 生成，请勿手工编辑。
# 它取代了以前的 files_info：不再由客户端解析「要下载哪些文件」，而是由这里自己
# 完成下载与落盘。好处是只列出真正变动的文件 —— 这次没碰 help.py，就不必再下一遍。
# 目录结构变更的迁移也写在这个脚本里。
#
# 客户端保证以下环境变量：
#
#   MACWAVE_INSTALL_DIR      安装根目录
#   MACWAVE_CORE_URL         MacWave 代码的地址前缀（不含分支）
#   MACWAVE_BRANCH           代码分支
#   MACWAVE_CURRENT_VERSION  当前已装版本；首次安装时为空
#   MACWAVE_FILE_TIMEOUT     单个文件的超时秒数
#   MACWAVE_NEED_SUDO        1 = 安装目录需要 sudo 才能写
#   MACWAVE_LANG             zh = 中文输出；未设置或其它值 = 英文
#
# 约定：
#   - 任何一步失败都要 exit 非零；客户端据此判定「什么都没更新」，不写 VERSION.json
#   - 必须幂等：重跑一次不能把已经就位的东西弄坏

set -u

: "${MACWAVE_INSTALL_DIR:?MACWAVE_INSTALL_DIR is required}"
: "${MACWAVE_CORE_URL:?MACWAVE_CORE_URL is required}"

# 语言：install.sh 通过 MACWAVE_LANG 传进来。老版本客户端不会传，所以默认英文。
# 与 lib/install.sh 用同一套约定（mw_say "<English>" "<中文>"），不引 gettext。
MW_LANG="${MACWAVE_LANG:-en}"
mw_strip_item() {
    # --raw（install.sh 传下来的 MACWAVE_RAW=1）：去掉行首的 🌊 与紧跟的一个空格。
    # 与 `wave install --raw` 同一条规则；本脚本的几条提示都带 🌊，落进日志会脏。
    # 🌊 用 printf 的字节写：$'\U0001F30A' 在 bash 3.2 上不支持。
    local line="$1" item
    [[ "${MACWAVE_RAW:-}" == "1" ]] || { printf '%s' "$line"; return 0; }
    item="$(printf '\xf0\x9f\x8c\x8a')"
    case "$line" in
        "$item "*) line="${line#"$item "}" ;;
        "$item"*) line="${line#"$item"}" ;;
    esac
    printf '%s' "$line"
}
mw_say() {
    if [[ "$MW_LANG" == "zh" ]]; then printf '%b\n' "$(mw_strip_item "$2")"; else printf '%b\n' "$(mw_strip_item "$1")"; fi
}
mw_say_err() {
    if [[ "$MW_LANG" == "zh" ]]; then printf '%b\n' "$(mw_strip_item "$2")" >&2; else printf '%b\n' "$(mw_strip_item "$1")" >&2; fi
}
: "${MACWAVE_BRANCH:?MACWAVE_BRANCH is required}"

VERSION="4.4.1"
BRANCH="4.4"
FILE_TIMEOUT="${MACWAVE_FILE_TIMEOUT:-60}"
ATTEMPTS=3

# 额外根证书（MACWAVE_CACERT）：企业网络里 TLS 会被重签，自建镜像也可能用私有 CA。
# 这个脚本是客户端调起来的，环境变量直接继承；没设时行为不变。
# 设了却读不到就报错退出 —— 静默忽略会让人以为已经信任了那家 CA。
CURL_CACERT=""
if [[ -n "${MACWAVE_CACERT:-}" ]]; then
    _cacert="${MACWAVE_CACERT/#\~/$HOME}"
    if [[ ! -f "$_cacert" || ! -r "$_cacert" ]]; then
        mw_say_err "🌊 Error: MACWAVE_CACERT is not a readable file: $_cacert" "🌊 错误：MACWAVE_CACERT 不是一个可读的文件：$_cacert"
        mw_say_err "🌊 Next      export MACWAVE_CACERT=/path/to/root.pem (or unset it)" "🌊 下一步     export MACWAVE_CACERT=/path/to/root.pem（或取消这个变量）"
        exit 1
    fi
    CURL_CACERT="$_cacert"
fi

run() {
    if [ "${MACWAVE_NEED_SUDO:-}" = "1" ]; then
        sudo "$@"
    else
        "$@"
    fi
}

redact_url() {
    # 报错里的地址要打码：用镜像时 MACWAVE_CORE_URL 是
    # https://<用户>:<密码>@mirror/...，原样打印等于把密码写进终端滚屏、
    # CI 日志和用户贴出来的求助截图。
    #
    # 只在 // 之后、第一个 / 之前找最后一个 @ —— 路径里带 @ 是正常的
    # （jq@1.8.2.arm64），拿整条串找 @ 会把包名当成密码位置，地址就改坏了。
    local url="$1" rest authority path userinfo host user
    rest=${url#*://}
    [ "$rest" = "$url" ] && { printf '%s' "$url"; return; }
    authority=${rest%%/*}
    case "$rest" in
        */*) path="/${rest#*/}" ;;
        *)   path="" ;;
    esac
    if [[ "$authority" != *@* ]]; then
        printf '%s' "$url"
        return
    fi
    userinfo=${authority%@*}
    host=${authority##*@}
    user=${userinfo%%:*}
    if [[ "$userinfo" == *:* ]]; then
        printf '%s://%s:***@%s%s' "${url%%://*}" "$user" "$host" "$path"
    else
        printf '%s://***@%s%s' "${url%%://*}" "$host" "$path"
    fi
}

fetch() {
    # fetch <url> <目标>：先写 .macwave-part 再 mv，重试期间目标位置不会出现半个文件
    local url="$1" destination="$2" attempt status partial
    partial="$destination.macwave-part"

    run mkdir -p "$(dirname "$destination")"
    for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
        status=0
        run curl -fsSL --max-time "$FILE_TIMEOUT" ${CURL_CACERT:+--cacert "$CURL_CACERT"} -o "$partial" "$url" || status=$?
        if [ "$status" -eq 0 ]; then
            # mv 失败也要报：权限不足（sudo 没拿到）时文件还在 .macwave-part 里，
            # 目标位置是旧的甚至不存在。以前这里不看返回值，于是「下载成功但没就位」
            # 会被当成这一步成功 —— 和 want 里那个 return/exit 是同一类问题。
            if ! run mv -f "$partial" "$destination"; then
                mw_say_err "🌊 Error: cannot move $partial into place" "🌊 错误：无法把 $partial 移动到目标位置"
                run rm -f "$partial" 2>/dev/null || true
                return 1
            fi
            return 0
        fi
        run rm -f "$partial" 2>/dev/null || true
        if ((attempt < ATTEMPTS)); then
            sleep 2
        fi
    done
    return 1
}

file_sha256() {
    # 用 openssl 而不是 shasum：install.sh / selfupdate.sh 里验签名已经要用它，
    # 少一个依赖就少一种「某台机器上没有那个命令」的失败。
    openssl dgst -sha256 -r "$1" 2>/dev/null | awk '{print $1}'
}

verify_hash() {
    # verify_hash <仓库内路径> <已下载的文件> <期望哈希>
    #
    # 4.4 是**实验期**：默认只警告，装还是照装。理由是老客户端拿不到这份判断
    # （它们跑的是自己那份老脚本），真正的强制要等客户端版本铺开。开关：
    #   MACWAVE_WANT_HASHES=1   客户端要求校验（由 install.sh / selfupdate.sh 置）
    #   MACWAVE_STRICT_HASHES=1 不符即失败（未来的默认，现在不设）
    local repo_path="$1" file="$2" expect="$3" got
    got="$(file_sha256 "$file")"
    [ -n "$expect" ] || return 0
    [ "$got" = "$expect" ] && return 0

    if [ "${MACWAVE_STRICT_HASHES:-}" = "1" ]; then
        mw_say_err "🌊 Error: $repo_path does not match the signed manifest" \
                   "🌊 错误：$repo_path 与已签名清单不符"
        mw_say_err "🌊   expected $expect" "🌊   期望 $expect"
        mw_say_err "🌊   got      ${got:-<unreadable>}" "🌊   实际 ${got:-读不到}"
        exit 1
    fi

    mw_say_err "🌊 Warning: $repo_path does not match the signed manifest (continuing)" \
               "🌊 警告：$repo_path 与已签名清单不符（继续安装）"
    mw_say_err "🌊   expected $expect" "🌊   期望 $expect"
    mw_say_err "🌊   got      ${got:-<unreadable>}" "🌊   实际 ${got:-读不到}"
    return 0
}

want() {
    # want <仓库内路径> <是否 +x> [期望的 sha256]
    local repo_path="$1" exec_flag="${2:-0}" expect_sha="${3:-}"
    local destination="$MACWAVE_INSTALL_DIR/$repo_path"
    local url="$MACWAVE_CORE_URL/$MACWAVE_BRANCH/$repo_path"

    if [ "${MACWAVE_SILENT:-}" != "1" ]; then
        mw_say "🌊 Downloading $repo_path..." "🌊 正在下载 ${repo_path}……"
    fi
    if ! fetch "$url" "$destination"; then
        mw_say_err "🌊 Error: cannot download $repo_path" "🌊 错误：无法下载 $repo_path"
        echo "🌊   $(redact_url "$url")" >&2
        # 404 有两种完全不同的原因：单个文件被删了，或者整棵 core/<分支>/ 压根没同步。
        # 后者是新分支上线当天的常态（镜像一天只跑一次），而且症状看起来一模一样 ——
        # 2026-11-19 装 4.4.0 时就被这条绕了：日志里只说某一个文件下不到。
        mw_say_err "🌊 If every file fails like this, the mirror has not synced branch $MACWAVE_BRANCH yet." \
                   "🌊 如果每个文件都这样，说明镜像还没同步 ${MACWAVE_BRANCH} 这个分支。"
        mw_say_err "🌊 Run scripts/mirror-sync/mirror-sync.sh on the mirror (see docs/MIRROR-SETUP.md)." \
                   "🌊 在镜像机上跑 scripts/mirror-sync/mirror-sync.sh（见 docs/MIRROR-SETUP.md）。"
        # 必须 exit 而不是 return：install_fresh / install_delta 是一串裸的
        # `want ...`，没有 `|| exit`，脚本也没有 set -e。用 return 1 的话
        # 调用方不看返回值，于是「有文件没下到」会被当成更新成功，客户端照旧
        # 写 VERSION.json —— 安装树缺文件但版本号已经前进了，这种状态最难查。
        # 2026-10-30 的 4.1.1 就是这样：两个 __pycache__ 路径 404 之后，
        # 那一步仍然打印了 "MacWave has been updated to 4.1.1!"。
        exit 1
    fi
    # 校验放在 chmod 之前：先确认字节对不对，再决定要不要给它执行位
    if [ "${MACWAVE_WANT_HASHES:-}" = "1" ] && [ -n "$expect_sha" ]; then
        verify_hash "$repo_path" "$destination" "$expect_sha"
    fi
    if [ "$exec_flag" = "1" ]; then
        # 加不上 +x 的后果是「命令找不到」，比下载失败更难懂，所以这里也要拦住
        if ! run chmod +x "$destination"; then
            mw_say_err "🌊 Error: cannot make $repo_path executable" "🌊 错误：无法把 $repo_path 设为可执行"
            exit 1
        fi
    fi
    return 0
}

install_fresh() {
    # 首次安装（或修复一棵不完整的安装树）：所有文件都要。
    want Keys/D0E229FB.asc 0 f2852806fdd64f2df320e6446aa704455b4c85cfa27bead7d29ecf32e3d7647b
    want Keys/macwave-rsa.pub.pem 0 4b15601f77a302cc1ba2610cd3d96ff1e8982da98a401555eaa225fea6473c17
    want cli/commands.py 0 754cb98581a7a6e29dbd9ff2994ee3e6ee54122286e12abb458916b9d9b11981
    want cli/common.py 0 6350ff4bb44b6f952ad884a97334c36edb0f153de82fc14405c97b790109bf3f
    want cli/flags.py 0 b821fd8915d150fea483e54c8b3c765eea58a4474e22a96bbecc172346a92db5
    want cli/help.py 0 b344751f998d9685ff1fce92a72d4bf3bc80e1454b8c77c8a293275e1b9fd1a0
    want cli/help_zh.py 0 e9bbf20f0289f0309f42778cb50887ab5afab8a96098ffa9327e02c576706267
    want cli/manual.py 0 0993d72f5c218bf803d6db0de1a2b198531915dd9af1b059053bac4ab6d38ca8
    want cli/silent.py 0 c2001bca0bf19c698533b1ee79982037ea34ce3179da189b45a404d127c31c64
    want cli/suggest.py 0 3255dfe43c8dd462a9577ef11ff43e97aaebe7e07e432321237c105a78919144
    want config/configerror.py 0 899e67abd20e8adaa4370fefbbf3f4554c628b33a93497b485c7899e3e0245d8
    want config/configpaths.py 0 c9c3493e16b2e253e566a8f8639e3024717f7ff8309270e539ac8e50611cacc7
    want config/envvar.py 0 d8b68e8237b91dad9bd564ba9b04d76c3c18b5845d0b44c7608089a728c56ec2
    want info/wave-zh.info 0 d43dd2548f46555aa0c1650acf370c631306b795d1f6d74d8a5c8c5b9ef277c0
    want info/wave.info 0 4f113de2c0641aa58c24e5bfaf25adb312a4e2a193521732a948a107b4e35614
    want lib/latest.py 0 12b310d0fa8837164ad57c0536562faa994a340d60b5cecd4f534a2a38aceb0f
    want lib/mirrorinfo.py 0 f85e41ab1fa6863a36971ea630e33b38ad1d97d9936919c1ffbb2581a359398b
    want lib/selfupdate.py 0 ced0ebbdba13047deea414c00ff624ebfd78a302375a44109a55470f09f5ceaa
    want lib/selfupdate.sh 1 274818ca38339af9ee9a35251b3e469200c2fb6d6d5c67951d50165cb18c88dd
    want lib/shellenv.py 0 532f563b9c5d4a6e1204f250a001fcdcf80cfc51e9fa470ac0e1c07664436e00
    want lib/steplog.py 0 d52a7651a529ad8121edff354ff546c5773987c612580c1caf9cd6d540b5b89f
    want lib/versioncompare.py 0 ee91f010e37f13f25377cf9a64074a8156f5e089ccbe6311bad28b0fa7840f7b
    want lib/wave.py 0 81c9f6c60a74259b9c9815399619caae8d0b44af736d15a23f614d05759c6dc8
    want man/man1/wave-info-zh.1 0 f48bd0ff17281f1e3a5e18f87cc726cc64693a0e392e7638e0033cb284971a2b
    want man/man1/wave-info.1 0 9da9ddf74bf0e2387c40adf3d2f31152b3d4bc7307ee173f00bf21f3f50a22b8
    want man/man1/wave-install-zh.1 0 e376a7f724eedd287a9956de88a1f856e2af320e7e4c4dab7c5b96cda33bb9d1
    want man/man1/wave-install.1 0 8b0d6e3260d76da7283a78f8ee12660209a6698bb937b34d1352d3865b96d6df
    want man/man1/wave-latest-zh.1 0 ed1f5276bf0b44cd0db8e664d05320e36b4756a693d3ab838b1e718f760697e3
    want man/man1/wave-latest.1 0 081485b3d0c38cf15966ff51730343dfc0302822db9f7232fdcb7619758c18e8
    want man/man1/wave-link-zh.1 0 6d265481ca929613a02cbfe2d7dc05a5368211f2b933d4888a4af17b45bd9cc5
    want man/man1/wave-link.1 0 d7db9e9e2f978d9d3392c8da6dc7a6d4f4fbe77c4e6fd0c5cbdade2e1ad7130c
    want man/man1/wave-linkquery-zh.1 0 38d859b643e01e6881b3b772e61d0f5fdfe2c7fb0c75014080192e789cfc004f
    want man/man1/wave-linkquery.1 0 d6955a1aa3db03bd3088743a64fd3fdc36a624a85b73a1c54ac953a8b291665f
    want man/man1/wave-list-zh.1 0 d939da75ba6a81be657d09ecbf7831015f5ca47c299254c15e3b4779c01d642d
    want man/man1/wave-list.1 0 c5acd67dbc1399f9c1681765f863b9c8bc58fcd1ea9934fad47b204bd4e243cd
    want man/man1/wave-manual-zh.1 0 5a11c68ee6c8dd999adc0acc385aae2c67fac89ec97e031ea630b492b89dbe53
    want man/man1/wave-manual.1 0 779d40ae204522e0c008ba60cf8834c99251ffce341c5f5a1723a354b36cba87
    want man/man1/wave-mirror-zh.1 0 623513e06a2877f971af2ee99ab367f98c65965ea162e8d78019fb5bf73e8f29
    want man/man1/wave-mirror.1 0 367d56d9c82726c0c9a2965e2a76d3e5bdc6cff46e8813cbbd81a21369fecc4d
    want man/man1/wave-search-zh.1 0 12f1b43b2cc491b393193095ec2e76d164c6eb15a6827d957c22e67ff99d3010
    want man/man1/wave-search.1 0 e9e46f04ed945c9fe12a255059b14184fd0e81b7ba51d2fc60ae33fe27b65119
    want man/man1/wave-selfupdate-zh.1 0 60aeb2489b676dfcf2c5fb32c327f60b41bb7f326df6fbb570faf9152a53a503
    want man/man1/wave-selfupdate.1 0 8e74e2ecb933e8f18cea8b6eda3d01a0c7d9d5abd32d5408b717c91022213b64
    want man/man1/wave-shellenv-zh.1 0 9c0f5ab10dbe1a7d983831d5fc2a826fa62cee2603f95bf6eee20b050e59853d
    want man/man1/wave-shellenv.1 0 7d1e1e5ab73060ba0e1389680c7a5c3e64f9054397d00c3dcf3b41ef991d3b64
    want man/man1/wave-uninstall-zh.1 0 d01727cbc83d246946db256f8d22d48338ac64e5d2058ebeec57853136fe1bfb
    want man/man1/wave-uninstall.1 0 2e52d4f343d8a5e596e4aa4b6f0bb3303f155c9ab5a5aead7c47c1b82dabaaf6
    want man/man1/wave-unlink-zh.1 0 e6251ff7992638b5f9488cf423a8646d2badd9d18271d4db9c29ae06538b3b44
    want man/man1/wave-unlink.1 0 4f328b17fbaa8cad9c71d71700ad9ec93b9bcf6a2711fdbd26337a2c74b6bc8d
    want man/man1/wave-upgrade-zh.1 0 1db954c47a0854e3c6d7600b107938649e83ba4d3f2ff9337acba1f2500ecf81
    want man/man1/wave-upgrade.1 0 974e0246b0f4c9bf102c7a84baaeb0ca8b9a74f1ad98976c7dd023e44298ced1
    want man/man1/wave-version-zh.1 0 cbda4c08b1f9b322bd025d5170acd50b170b56512b48d065a2037526235ccee8
    want man/man1/wave-version.1 0 bb93d7e16b6f2bf24851df7ec6260c795225dfa1f1c886a501f3471f30bfef17
    want man/man1/wave-zh.1 0 cf4d473ee3d7fe32efbbbbaa612beac4ad17789177a048f69a5a4880d07f1eae
    want man/man1/wave.1 0 768487be16c329525c3e495144fe5c2e92bd6a8d203f57a8cb97b677cd2235c7
    want net/domains.py 0 caec14ca8fd8dbf28cec5b41b9dc81a9caf7de79b7e4b144e7d6a1d0e0e38ad8
    want net/signature.py 0 b77c0b755265ec5bc18c818737c512852325b09c4129f55a607c55205d7fd62f
    want net/timeouts.py 0 5fb423ff10eef581faa6dc55eed66062377b6d6d274fccd7a427217c87209ed6
    want net/tls.py 0 32dac87a9e197f1b9d492dcc8549e48a715e398ee321d1bcc8b6daade003bd52
    want pkg/linker.py 0 37809a1911d86c7454c03ef85b342893723790d5a15f504d2cc80b642b549f1d
    want pkg/pkginfohelper.py 0 8e5a848546337f1e81a7744aacaad91848b5d4fab5c42f598daf1aa271bba0f7
    want pkg/pkginstaller.py 0 f2628397336026e99a61d2c4b96e70b256bbfd126f5a503cfe713175041012d2
    want pkg/pkginstaller.sh 1 f36e088ead500f44aa3b9cfa052057892daf7531eb8027616491c6e39c779dd8
    want pkg/pkgunzip.sh 1 a2304c89fc8ea4392deaf12dadf66fc4c90719319a968b09f430c73460c35260
    want pkg/uninstaller.py 0 1ed934c7a3fd3bd6000476aa876a7c3736c72c7a8e11644f4103bacf3e71c6ce
    want pkg/upgrader.py 0 34adef93e0dbbf74814f33fa63669e93d53a520f268238ae6694b13fa84d9101
    want surfboard/depsinstaller.py 0 c3def789ce09f168d14581c527637c732aa37bb4bc3fff6dcf91bde493759ad8
    want surfboard/depsinstaller.sh 1 a4a42058c24f687cdd925b7401b626613dcf36c03fa91c29a0f6081dfcfb1d8b
    want surfboard/depsmanager.sh 1 fb4b3ee8246c082b11c30a0600a75ec83bea7861e3a2ce8dc988192687d48f79
    want surfboard/querier.py 0 109a635c73aabdc9958885d6401549489c0d28237d586802fb661c47f7d717cb
    want surfboard/tagger.sh 1 45a794e9b662a04c82b3736d7472e64adb5771cfc0f26d73163592407015aee0
    want surfboard/transfer.sh 1 7a6c8e46e10772f496deb753ceab075815e5607a407f53d9e5824174991d91c8
}

install_delta() {
    # 从上一版升级：只取这一版变动过的文件。
    # 没列出的文件保持不变 —— 它们的字节和上一版相同。
    want Keys/D0E229FB.asc 0 f2852806fdd64f2df320e6446aa704455b4c85cfa27bead7d29ecf32e3d7647b
    want Keys/macwave-rsa.pub.pem 0 4b15601f77a302cc1ba2610cd3d96ff1e8982da98a401555eaa225fea6473c17
    want cli/commands.py 0 754cb98581a7a6e29dbd9ff2994ee3e6ee54122286e12abb458916b9d9b11981
    want cli/common.py 0 6350ff4bb44b6f952ad884a97334c36edb0f153de82fc14405c97b790109bf3f
    want cli/flags.py 0 b821fd8915d150fea483e54c8b3c765eea58a4474e22a96bbecc172346a92db5
    want cli/help.py 0 b344751f998d9685ff1fce92a72d4bf3bc80e1454b8c77c8a293275e1b9fd1a0
    want cli/help_zh.py 0 e9bbf20f0289f0309f42778cb50887ab5afab8a96098ffa9327e02c576706267
    want cli/manual.py 0 0993d72f5c218bf803d6db0de1a2b198531915dd9af1b059053bac4ab6d38ca8
    want cli/silent.py 0 c2001bca0bf19c698533b1ee79982037ea34ce3179da189b45a404d127c31c64
    want cli/suggest.py 0 3255dfe43c8dd462a9577ef11ff43e97aaebe7e07e432321237c105a78919144
    want config/configerror.py 0 899e67abd20e8adaa4370fefbbf3f4554c628b33a93497b485c7899e3e0245d8
    want config/configpaths.py 0 c9c3493e16b2e253e566a8f8639e3024717f7ff8309270e539ac8e50611cacc7
    want config/envvar.py 0 d8b68e8237b91dad9bd564ba9b04d76c3c18b5845d0b44c7608089a728c56ec2
    want info/wave-zh.info 0 d43dd2548f46555aa0c1650acf370c631306b795d1f6d74d8a5c8c5b9ef277c0
    want info/wave.info 0 4f113de2c0641aa58c24e5bfaf25adb312a4e2a193521732a948a107b4e35614
    want lib/latest.py 0 12b310d0fa8837164ad57c0536562faa994a340d60b5cecd4f534a2a38aceb0f
    want lib/mirrorinfo.py 0 f85e41ab1fa6863a36971ea630e33b38ad1d97d9936919c1ffbb2581a359398b
    want lib/selfupdate.py 0 ced0ebbdba13047deea414c00ff624ebfd78a302375a44109a55470f09f5ceaa
    want lib/selfupdate.sh 1 274818ca38339af9ee9a35251b3e469200c2fb6d6d5c67951d50165cb18c88dd
    want lib/shellenv.py 0 532f563b9c5d4a6e1204f250a001fcdcf80cfc51e9fa470ac0e1c07664436e00
    want lib/steplog.py 0 d52a7651a529ad8121edff354ff546c5773987c612580c1caf9cd6d540b5b89f
    want lib/versioncompare.py 0 ee91f010e37f13f25377cf9a64074a8156f5e089ccbe6311bad28b0fa7840f7b
    want lib/wave.py 0 81c9f6c60a74259b9c9815399619caae8d0b44af736d15a23f614d05759c6dc8
    want man/man1/wave-info-zh.1 0 f48bd0ff17281f1e3a5e18f87cc726cc64693a0e392e7638e0033cb284971a2b
    want man/man1/wave-info.1 0 9da9ddf74bf0e2387c40adf3d2f31152b3d4bc7307ee173f00bf21f3f50a22b8
    want man/man1/wave-install-zh.1 0 e376a7f724eedd287a9956de88a1f856e2af320e7e4c4dab7c5b96cda33bb9d1
    want man/man1/wave-install.1 0 8b0d6e3260d76da7283a78f8ee12660209a6698bb937b34d1352d3865b96d6df
    want man/man1/wave-latest-zh.1 0 ed1f5276bf0b44cd0db8e664d05320e36b4756a693d3ab838b1e718f760697e3
    want man/man1/wave-latest.1 0 081485b3d0c38cf15966ff51730343dfc0302822db9f7232fdcb7619758c18e8
    want man/man1/wave-link-zh.1 0 6d265481ca929613a02cbfe2d7dc05a5368211f2b933d4888a4af17b45bd9cc5
    want man/man1/wave-link.1 0 d7db9e9e2f978d9d3392c8da6dc7a6d4f4fbe77c4e6fd0c5cbdade2e1ad7130c
    want man/man1/wave-linkquery-zh.1 0 38d859b643e01e6881b3b772e61d0f5fdfe2c7fb0c75014080192e789cfc004f
    want man/man1/wave-linkquery.1 0 d6955a1aa3db03bd3088743a64fd3fdc36a624a85b73a1c54ac953a8b291665f
    want man/man1/wave-list-zh.1 0 d939da75ba6a81be657d09ecbf7831015f5ca47c299254c15e3b4779c01d642d
    want man/man1/wave-list.1 0 c5acd67dbc1399f9c1681765f863b9c8bc58fcd1ea9934fad47b204bd4e243cd
    want man/man1/wave-manual-zh.1 0 5a11c68ee6c8dd999adc0acc385aae2c67fac89ec97e031ea630b492b89dbe53
    want man/man1/wave-manual.1 0 779d40ae204522e0c008ba60cf8834c99251ffce341c5f5a1723a354b36cba87
    want man/man1/wave-mirror-zh.1 0 623513e06a2877f971af2ee99ab367f98c65965ea162e8d78019fb5bf73e8f29
    want man/man1/wave-mirror.1 0 367d56d9c82726c0c9a2965e2a76d3e5bdc6cff46e8813cbbd81a21369fecc4d
    want man/man1/wave-search-zh.1 0 12f1b43b2cc491b393193095ec2e76d164c6eb15a6827d957c22e67ff99d3010
    want man/man1/wave-search.1 0 e9e46f04ed945c9fe12a255059b14184fd0e81b7ba51d2fc60ae33fe27b65119
    want man/man1/wave-selfupdate-zh.1 0 60aeb2489b676dfcf2c5fb32c327f60b41bb7f326df6fbb570faf9152a53a503
    want man/man1/wave-selfupdate.1 0 8e74e2ecb933e8f18cea8b6eda3d01a0c7d9d5abd32d5408b717c91022213b64
    want man/man1/wave-shellenv-zh.1 0 9c0f5ab10dbe1a7d983831d5fc2a826fa62cee2603f95bf6eee20b050e59853d
    want man/man1/wave-shellenv.1 0 7d1e1e5ab73060ba0e1389680c7a5c3e64f9054397d00c3dcf3b41ef991d3b64
    want man/man1/wave-uninstall-zh.1 0 d01727cbc83d246946db256f8d22d48338ac64e5d2058ebeec57853136fe1bfb
    want man/man1/wave-uninstall.1 0 2e52d4f343d8a5e596e4aa4b6f0bb3303f155c9ab5a5aead7c47c1b82dabaaf6
    want man/man1/wave-unlink-zh.1 0 e6251ff7992638b5f9488cf423a8646d2badd9d18271d4db9c29ae06538b3b44
    want man/man1/wave-unlink.1 0 4f328b17fbaa8cad9c71d71700ad9ec93b9bcf6a2711fdbd26337a2c74b6bc8d
    want man/man1/wave-upgrade-zh.1 0 1db954c47a0854e3c6d7600b107938649e83ba4d3f2ff9337acba1f2500ecf81
    want man/man1/wave-upgrade.1 0 974e0246b0f4c9bf102c7a84baaeb0ca8b9a74f1ad98976c7dd023e44298ced1
    want man/man1/wave-version-zh.1 0 cbda4c08b1f9b322bd025d5170acd50b170b56512b48d065a2037526235ccee8
    want man/man1/wave-version.1 0 bb93d7e16b6f2bf24851df7ec6260c795225dfa1f1c886a501f3471f30bfef17
    want man/man1/wave-zh.1 0 cf4d473ee3d7fe32efbbbbaa612beac4ad17789177a048f69a5a4880d07f1eae
    want man/man1/wave.1 0 768487be16c329525c3e495144fe5c2e92bd6a8d203f57a8cb97b677cd2235c7
    want net/domains.py 0 caec14ca8fd8dbf28cec5b41b9dc81a9caf7de79b7e4b144e7d6a1d0e0e38ad8
    want net/signature.py 0 b77c0b755265ec5bc18c818737c512852325b09c4129f55a607c55205d7fd62f
    want net/timeouts.py 0 5fb423ff10eef581faa6dc55eed66062377b6d6d274fccd7a427217c87209ed6
    want net/tls.py 0 32dac87a9e197f1b9d492dcc8549e48a715e398ee321d1bcc8b6daade003bd52
    want pkg/linker.py 0 37809a1911d86c7454c03ef85b342893723790d5a15f504d2cc80b642b549f1d
    want pkg/pkginfohelper.py 0 8e5a848546337f1e81a7744aacaad91848b5d4fab5c42f598daf1aa271bba0f7
    want pkg/pkginstaller.py 0 f2628397336026e99a61d2c4b96e70b256bbfd126f5a503cfe713175041012d2
    want pkg/pkginstaller.sh 1 f36e088ead500f44aa3b9cfa052057892daf7531eb8027616491c6e39c779dd8
    want pkg/pkgunzip.sh 1 a2304c89fc8ea4392deaf12dadf66fc4c90719319a968b09f430c73460c35260
    want pkg/uninstaller.py 0 1ed934c7a3fd3bd6000476aa876a7c3736c72c7a8e11644f4103bacf3e71c6ce
    want pkg/upgrader.py 0 34adef93e0dbbf74814f33fa63669e93d53a520f268238ae6694b13fa84d9101
    want surfboard/depsinstaller.py 0 c3def789ce09f168d14581c527637c732aa37bb4bc3fff6dcf91bde493759ad8
    want surfboard/depsinstaller.sh 1 a4a42058c24f687cdd925b7401b626613dcf36c03fa91c29a0f6081dfcfb1d8b
    want surfboard/depsmanager.sh 1 fb4b3ee8246c082b11c30a0600a75ec83bea7861e3a2ce8dc988192687d48f79
    want surfboard/querier.py 0 109a635c73aabdc9958885d6401549489c0d28237d586802fb661c47f7d717cb
    want surfboard/tagger.sh 1 45a794e9b662a04c82b3736d7472e64adb5771cfc0f26d73163592407015aee0
    want surfboard/transfer.sh 1 7a6c8e46e10772f496deb753ceab075815e5607a407f53d9e5824174991d91c8
}

# 本版安装树应有的全部文件（与 install_fresh 同一份清单，见生成器里的 list_lines）。
FULL_FILES="
Keys/D0E229FB.asc
Keys/macwave-rsa.pub.pem
cli/commands.py
cli/common.py
cli/flags.py
cli/help.py
cli/help_zh.py
cli/manual.py
cli/silent.py
cli/suggest.py
config/configerror.py
config/configpaths.py
config/envvar.py
info/wave-zh.info
info/wave.info
lib/latest.py
lib/mirrorinfo.py
lib/selfupdate.py
lib/selfupdate.sh
lib/shellenv.py
lib/steplog.py
lib/versioncompare.py
lib/wave.py
man/man1/wave-info-zh.1
man/man1/wave-info.1
man/man1/wave-install-zh.1
man/man1/wave-install.1
man/man1/wave-latest-zh.1
man/man1/wave-latest.1
man/man1/wave-link-zh.1
man/man1/wave-link.1
man/man1/wave-linkquery-zh.1
man/man1/wave-linkquery.1
man/man1/wave-list-zh.1
man/man1/wave-list.1
man/man1/wave-manual-zh.1
man/man1/wave-manual.1
man/man1/wave-mirror-zh.1
man/man1/wave-mirror.1
man/man1/wave-search-zh.1
man/man1/wave-search.1
man/man1/wave-selfupdate-zh.1
man/man1/wave-selfupdate.1
man/man1/wave-shellenv-zh.1
man/man1/wave-shellenv.1
man/man1/wave-uninstall-zh.1
man/man1/wave-uninstall.1
man/man1/wave-unlink-zh.1
man/man1/wave-unlink.1
man/man1/wave-upgrade-zh.1
man/man1/wave-upgrade.1
man/man1/wave-version-zh.1
man/man1/wave-version.1
man/man1/wave-zh.1
man/man1/wave.1
net/domains.py
net/signature.py
net/timeouts.py
net/tls.py
pkg/linker.py
pkg/pkginfohelper.py
pkg/pkginstaller.py
pkg/pkginstaller.sh
pkg/pkgunzip.sh
pkg/uninstaller.py
pkg/upgrader.py
surfboard/depsinstaller.py
surfboard/depsinstaller.sh
surfboard/depsmanager.sh
surfboard/querier.py
surfboard/tagger.sh
surfboard/transfer.sh
"

tree_complete() {
    # 判断这棵安装树是不是「本版应有的文件一个不缺」。
    #
    # 为什么不能只看 lib/wave.py 在不在：那种判据会把三种坏树当成好树 ——
    #   1. 上一版留下的一半升级（下到第 20 个文件时断网 / Ctrl-C）
    #   2. 跨版本跳级升级：4.1.0 直接升 4.3.3，delta 只含 4.3.2→4.3.3 的差异
    #   3. 文件被手工删过（2026-11-15 就出现过：4.4 的迁移删掉 lib/configerror.py，
    #      但 lib/wave.py 还是 4.3.x 的，于是 wave 连启动都做不到）
    # 缺一个就走全量，代价是多重下几个文件，换的是「永远能自愈」。
    local path
    for path in $FULL_FILES; do
        [ -e "$MACWAVE_INSTALL_DIR/$path" ] || return 1
    done
    return 0
}

main() {
    # 「已经是这个版本」也要先确认树是完整的。VERSION.json 只证明「上次跑完过」，
    # 不证明文件还在 —— 只信版本号的话，一棵坏树会永远停在 "Already at"，
    # 无论跑多少次都不会修好（这正是 2026-11-15 那次的形态）。
    if [ "${MACWAVE_FULL_INSTALL:-}" != "1" ] \
       && [ "${MACWAVE_CURRENT_VERSION:-}" = "$VERSION" ] \
       && tree_complete; then
        mw_say "🌊 Already at $VERSION; nothing to download." "🌊 已经是 ${VERSION}，无需下载。"
        return 0
    fi

    if [ "${MACWAVE_FULL_INSTALL:-}" = "1" ] || [ ! -f "$MACWAVE_INSTALL_DIR/lib/wave.py" ]; then
        mw_say "🌊 Installing MacWave $VERSION" "🌊 正在安装 MacWave $VERSION"
        install_fresh || return 1
    elif ! tree_complete; then
        # 树在那儿但不完整：增量的前提（「没变动的文件都是对的」）不成立，
        # 直接全量补齐。这里不先跑 delta —— 缺的文件正好可能就是它要留着的那些。
        # 两句要合成**一次**调用：mw_say 的第二个参数才是中文。分成两次的话，
        # 英文模式会看到中文那行、中文模式会看到英文那行 —— 2026-11-19 用户报的就是这个。
        mw_say "🌊 The installed tree is incomplete; reinstalling all of MacWave $VERSION" \
            "🌊 安装树不完整，正在重新安装 MacWave ${VERSION} 的全部文件"
        install_fresh || return 1
    else
        mw_say "🌊 Updating MacWave ${MACWAVE_CURRENT_VERSION:-unknown} -> $VERSION" "🌊 正在更新 MacWave ${MACWAVE_CURRENT_VERSION:-unknown} -> $VERSION"
        install_delta || return 1
        # 增量之后再确认一次：delta 只含「上一版 → 本版」的差异，跨版本跳级时
        # 会漏掉中间那些版本改过的文件。补全比报错好 —— 用户什么也没做错。
        if ! tree_complete; then
            mw_say "🌊 Some files are still missing after the update; fetching all of MacWave $VERSION" \
                "🌊 更新后仍有文件缺失，正在补齐 MacWave ${VERSION} 的全部文件"
            install_fresh || return 1
        fi
    fi

    # ── 目录结构变更的迁移写在这里 ──
    # 约束：以当前用户身份执行，需要管理员权限时自己 sudo，失败要 exit 非零，
    # 且必须幂等。

    # 4.1.6：传输层从 lib/ 搬到 net/。新位置的三个文件已由 install_delta 下好
    # （发版时用 --new 把它们排在 delta 最前面），这里只清掉旧位置的同名文件。
    # 不删其实也能跑 —— 没有代码再 import 它们 —— 但留着会让「安装树里到底有哪份
    # tls.py」变成两说，下次改策略时容易改到没人用的那一份。
    for stale in "$MACWAVE_INSTALL_DIR/lib/tls.py" \
                 "$MACWAVE_INSTALL_DIR/lib/timeouts.py" \
                 "$MACWAVE_INSTALL_DIR/lib/domains.py"; do
        if [ -f "$stale" ]; then
            run rm -f "$stale" || exit 1
        fi
    done

    # 4.4.0：配置解析与命令行层从 lib/ 搬到了 config/ 与 cli/。新位置的文件已经由
    # 上面的 install_fresh / install_delta 下好（`want` 会先 mkdir -p，所以这两个
    # 目录在旧安装树里也会被建出来），这里清掉 lib/ 下的平铺副本。
    #
    # 这一条比 4.1.6 那条**更**不能省：4.1.6 的旧文件已经没有代码 import，留着只是
    # 说不清；而这里 lib/ 仍在 sys.path 上，留着 lib/help.py 就等于「同一个模块有
    # 两份，哪份生效看路径顺序」—— wave.py 把 cli/ 排在 lib/ 之前，于是跑的是新的，
    # 但下一次有人调整顺序就会悄悄退回旧代码。删掉才没有第二种可能。
    #
    # lib/quiet.py 是漏过一次的：4.1.4 起它一直在清单里，4.4 把它并进了
    # cli/silent.py，但它没被列进这份删除名单 —— 于是从 4.1.4~4.3.3 升上来的树里
    # 会永久留一份没人 import 的 quiet.py。查出来时是 2026-11-15。
    for stale in "$MACWAVE_INSTALL_DIR/lib/configpaths.py" \
                 "$MACWAVE_INSTALL_DIR/lib/configerror.py" \
                 "$MACWAVE_INSTALL_DIR/lib/help.py" \
                 "$MACWAVE_INSTALL_DIR/lib/flags.py" \
                 "$MACWAVE_INSTALL_DIR/lib/suggest.py" \
                 "$MACWAVE_INSTALL_DIR/lib/silent.py" \
                 "$MACWAVE_INSTALL_DIR/lib/quiet.py"; do
        if [ -f "$stale" ]; then
            run rm -f "$stale" || exit 1
        fi
    done

    # 4.4.0：版本逻辑三份合成一份（lib/versioncompare.py）。pkg/pkgversionparser.py 与
    # surfboard/depsversionparser.py 已并进去，旧树里留着的那两份没有任何代码 import，
    # 所以删不删都跑得动 —— 但留着就是两套「差不多」的比较器躺在安装树里，下次改
    # 版本规则时很容易改到没人用的那一份。quiet.py 漏过一次，这里不重复。
    #
    # lib/versioncmp.py 是同一个模块的旧名字（4.4.0-beta1 起叫这个）。改成
    # versioncompare 之后旧文件没人 import 了，但留在 lib/ 里就是「同一个模块有两个
    # 名字」—— 与 help.py 那条同理，路径顺序一变就会悄悄跑旧代码。
    for stale in "$MACWAVE_INSTALL_DIR/pkg/pkgversionparser.py" \
                 "$MACWAVE_INSTALL_DIR/surfboard/depsversionparser.py" \
                 "$MACWAVE_INSTALL_DIR/lib/versioncmp.py"; do
        if [ -f "$stale" ]; then
            run rm -f "$stale" || exit 1
        fi
    done

    return 0
}

main "$@"
