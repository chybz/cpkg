##############################################################################
#
# Debian specific package building
#
##############################################################################
HAS_DEBIAN_INIT=0

function lp_init() {
    # Nothing to do
    return
}

function lp_prepare_package_directory() {
    mkdir -p $PKG_ROOTDIR/debian
    touch $PKG_ROOTDIR/TODO
}

function lp_handle_system_file() {
    local FILE=$1
    local TYPE=$2

    if [ "$TYPE" = "init" ]; then
        HAS_DEBIAN_INIT=1
    fi

    mv $FILE $PKG_ROOTDIR/debian/
}

function lp_handle_package_files() {
    local PHASE
    local CPKG_SCRIPT_BASE

    declare -A HAS_SCRIPTS
    HAS_SCRIPTS["postinst"]=0
    HAS_SCRIPTS["postrm"]=0
    HAS_SCRIPTS["preinst"]=0
    HAS_SCRIPTS["prerm"]=0

    if (($HAS_DEBIAN_INIT)); then
        HAS_SCRIPTS["postinst"]=1
        HAS_SCRIPTS["prerm"]=1
        HAS_SCRIPTS["postrm"]=1
    fi

    CPKG_SCRIPT=/tmp/cpkg-script.$$

    declare -A SCRIPT_SPECS
    SCRIPT_SPECS["configure"]="postinst";
    SCRIPT_SPECS["remove"]="postrm";
    SCRIPT_SPECS["purge"]="postrm";

    # Handle user-provided script snippets
    for PHASE in ${!SCRIPT_SPECS[@]}; do
        DPKG_PHASE=${SCRIPT_SPECS[${PHASE}]}

        if [ ! -f $PKG_ROOTDIR/$PKG_NAME.$PHASE ]; then
            continue
        fi

        DPKG_DEST=$PKG_ROOTDIR/debian/$PKG_NAME.$DPKG_PHASE

        HAS_SCRIPTS[${DPKG_PHASE}]=1

        cp_wrap_script_for_phase \
            $PKG_ROOTDIR/$PKG_NAME.$PHASE \
            $PHASE \
            $CPKG_SCRIPT

        cp_replace_template_var_from_file \
            $DPKG_DEST \
            "CPKG_${PHASE^^}" \
            $CPKG_SCRIPT
    done

    rm -f $CPKG_SCRIPT

    # Remove unused/empty package scripts (Debian policy)
    for PHASE in postinst postrm preinst prerm; do
        DPKG_SCRIPT=$PKG_ROOTDIR/debian/$PKG_NAME.$PHASE

        if [ ${HAS_SCRIPTS[$PHASE]} -eq 0 ]; then
            rm -f $DPKG_SCRIPT
        else
            cp_process_template $DPKG_SCRIPT
        fi
    done

    local FILES=$(find $PKG_ROOTDIR/debian -maxdepth 1 -type f | xargs)

    local TAG="##"
    local DIRVAL

    if [ -n "$FILES" ]; then
        for DIR in ${PACKAGE_DIRS}; do
            DIRVAL="${DIR}"
            cp_reinplace "s,${TAG}${DIR}${TAG},${!DIRVAL},g" $FILES
        done
    fi
}

function lp_clean_packages_scripts() {
    local FILES=$(
        find $PKG_ROOTDIR/debian -maxdepth 1 -type f | \
        xargs grep -l "#CPKG_.*"
    )

    if [ -n "$FILES" ]; then
        cp_reinplace "s,#CPKG_.*$,,g" $FILES
    fi
}

function lp_install_local_package() {
    sudo dpkg -i *.deb
}

function lp_install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get -y install $@
    lp_make_pkg_map
}

function lp_configure_package() {
    return
}

function lp_build_package() {
    cd $PKG_ROOTDIR

    echo "PKG_ARCH=$PKG_ARCH"
    cat debian/control

    if [ "$PKG_ARCH" = "all" ]; then
        dpkg-buildpackage -A -uc
    else
        dpkg-buildpackage -b -uc
    fi

    cd ..

    cp_msg "checking $PKG_NAME-$PKG_VER"

    lintian \
        -q \
        --suppress-tags bad-distribution-in-changes-file \
        --fail-on-warnings *.changes
}

function build_pkgconfig_filters() {
    local CACHE=$1

    local ARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null)

    cp_msg "building pkg-config header filters"

    set +e

    find /usr/lib -name \*.pc | while read PC; do
        pkg-config \
            --cflags-only-I \
            --silence-errors \
            $(basename $PC .pc) | \
        sed \
            -e "s/-I//g" \
            -e "s/ /\n/g" | \
        grep -v "^$"
    done | sort | uniq | \
    sed -r -e "s,/$,," | \
    egrep -v "^/usr/include$" | \
    sed \
        -r \
        -e "s,^/usr/(include|lib)/($ARCH/)?,s@^," \
        -e "s,$,/@@," | \
    egrep "^s@" \
        > $CACHE.filters

    set -e
}

function build_header_cache_from_repo() {
    local CACHE=$1

    local VER=$(lsb_release -sr)
    local CMD

    if dpkg --compare-versions "$VER" lt "9"; then
        # Before stretch
        CMD='zgrep -h "^usr/include/" /var/cache/apt/apt-file/*.gz'
    else
        # stretch or after
        CMD='/usr/lib/apt/apt-helper cat-file /var/lib/apt/lists/*Contents-*.lz4'
        CMD+=' | grep -h "^usr/include/"'
    fi

    if [[ "$HOST_ARCH" = "amd64" ]]; then
        # Filter out includes from libc6-dev-i386
        CMD+=' | grep -v libc6-dev-i386'
    fi

    eval "$CMD" | \
        sort -ur -k 1,1 | \
        sed \
            -r \
            -e "s,^usr/include/($ARCH/)?([^[:space:]]+)[[:space:]]+.+/([^/]*),\2 \3,g" \
            -f $CACHE.filters \
        > $CACHE.repo
}

function build_header_cache() {
    local CACHE=$1

    local ARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null)
    local HOST_ARCH=$(dpkg-architecture -qDEB_HOST_ARCH 2>/dev/null)

    build_pkgconfig_filters $CACHE

    cp_msg "building apt header cache"

    build_header_cache_from_repo $CACHE

    find /usr/include -type f -name \*.h\* | \
        xargs dpkg -S 2>&1 | \
        grep -v "^dpkg-query: " | \
        sed \
            -r \
            -e "s,^([^[:space:]:]+):([^[:space:]]*) /usr/include/([^[:space:]]+)$,\3 \1,g" \
            -f $CACHE.filters \
        > $CACHE.installed

    cat $CACHE.repo $CACHE.installed \
        | sort | uniq | \
        cdb -c -r -m $CACHE

    rm -f $CACHE.repo $CACHE.installed
}

function apt_file_update() {
    # Update apt-file data
    local CMD="apt-file update"

    if (($EUID != 0)); then
        CMD="sudo $CMD"
    fi

    cp_msg "updating apt-file data"

    $CMD >/dev/null
}

function build_pkg_cache() {
    local CACHE=$1

    cp_msg "building installed package cache"

    dpkg-query -W -f='${Package} ${Version} ${Status}\n' | \
        grep "install ok installed" | \
        sed \
            -r \
            -e "s, .*$, 1,g" | \
        cdb -c -m $CACHE
}

function lp_make_pkg_map() {
    cp_make_home

    local CACHE=$CPKG_HOME/packages.cache
    local REFFILE=/var/lib/dpkg/status
    local BUILD=0

    if [ ! -f $CACHE ]; then
        BUILD=1
    elif [ $REFFILE -nt $CACHE ]; then
        BUILD=1
    fi

    if (($BUILD == 1)); then
        build_pkg_cache $CACHE
    fi
}

function lp_make_pkg_header_map() {
    cp_make_home

    local CACHE=$CPKG_HOME/headers.cache
    local REFFILE
    local BUILD=0

    if [ ! -f $CACHE ]; then
        apt_file_update
        BUILD=1
    else
        for REFFILE in /var/lib/apt/lists/*_{InRelease,Release}; do
            if [ $REFFILE -nt $CACHE ]; then
                apt_file_update
                break
           fi
        done

        for REFFILE in /var/cache/apt/apt-file/*.gz /var/lib/dpkg/status; do
            if [ $REFFILE -nt $CACHE ]; then
                BUILD=1
                break
           fi
        done
    fi

    if (($BUILD == 1)); then
        build_header_cache $CACHE
    fi

    return 0
}

function build_pkgconfig_cache() {
    local CACHE=$1

    cp_msg "building apt pkg-config cache"

    local ARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null)
    local HOST_ARCH=$(dpkg-architecture -qDEB_HOST_ARCH 2>/dev/null)
    local -a PKGCONFIG_DIRS=(/usr/lib/pkgconfig)

    if [[ -n "$ARCH" ]]; then
        PKGCONFIG_DIRS+=(/usr/lib/$ARCH/pkgconfig)
    fi

    local -a PKGCONFIG_FILES
    local DIR

    for DIR in ${PKGCONFIG_DIRS[@]}; do
        PKGCONFIG_FILES+=($(find $DIR -type f -name \*.pc))
    done

    if ((${#PKGCONFIG_FILES[@]} > 0)); then
        dpkg -S ${PKGCONFIG_FILES[@]} 2>&1 | \
            grep -v "^dpkg-query: " | \
            sed \
                -r \
                -e "s,: [^[:space:]]+/pkgconfig/, ,g" \
                -e "s,:$HOST_ARCH,,g" \
                -e "s,\.pc,,g" \
                > $CACHE.tmp
    else
        touch $CACHE.tmp
    fi

    local PC
    local PKG
    local -A MAP

    while read PKG PC; do
        PC=${PC%.pc}

        if [[ "${MAP[$PKG]}" ]]; then
            MAP[$PKG]+=" $PC"
        else
            MAP[$PKG]=$PC
        fi
    done < $CACHE.tmp

    rm -f $CACHE.tmp

    for PKG in ${!MAP[@]}; do
        echo "$PKG ${MAP[$PKG]}"
    done | cdb -c -m $CACHE
}

function lp_make_pkgconfig_map() {
    cp_make_home

    local CACHE=$CPKG_HOME/pkgconfig.cache
    local REFDIR
    local BUILD=0

    local -a PKGCONFIG_DIRS=(/usr/lib/pkgconfig)

    if [[ -n "$ARCH" ]]; then
        PKGCONFIG_DIRS+=(/usr/lib/$ARCH/pkgconfig)
    fi

    if [ ! -f $CACHE ]; then
        BUILD=1
    else
        for REFDIR in ${PKGCONFIG_DIRS[@]}; do
            if [ $REFDIR -nt $CACHE ]; then
                BUILD=1
                break
            fi
        done
    fi

    if (($BUILD == 1)); then
        build_pkgconfig_cache $CACHE
    fi
}

function lp_get_pkgconfig() {
    local PC=$1
    shift

    local PCPATH=$PKG_CONFIG_PATH

    env PKG_CONFIG_PATH=$PCPATH pkg-config $@ $PC
}

function lp_full_pkg_name() {
    local PKG=$1

    echo $PKG
}
