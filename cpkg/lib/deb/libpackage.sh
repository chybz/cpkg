##############################################################################
#
# Debian specific package building
#
##############################################################################
HAS_DEBIAN_INIT=0

function lp_init() {
    # Nothing to do
}

function lp_prepare_package_directory() {
    mkdir -p $PKG_ROOTDIR/{debian,stage}
    touch $PKG_ROOTDIR/TODO
}

function lp_handle_manpage() {
    local MANPAGE=$1
    local MANSECT=$2

    echo $MANPAGE >> $PKG_ROOTDIR/debian/$PKG_NAME.manpages
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

    if [ $HAS_DEBIAN_INIT -ne 0 ]; then
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

        if [ ! -f $PKG_ROOTDIR/$PKG_PARTNAME.$PHASE ]; then
            continue
        fi

        DPKG_DEST=$PKG_ROOTDIR/debian/$PKG_NAME.$DPKG_PHASE

        HAS_SCRIPTS[${DPKG_PHASE}]=1

        wrap_script_for_phase \
            $PKG_ROOTDIR/$PKG_PARTNAME.$PHASE \
            $PHASE \
            $CPKG_SCRIPT

        replace_template_var_from_file \
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
            process_template $DPKG_SCRIPT
        fi
    done

    FILES=$(find $PKG_ROOTDIR/debian -maxdepth 1 -type f | xargs)

    local TAG="##"
    local DIRVAL

    if [ -n "$FILES" ]; then
        for DIR in ${PACKAGE_DIRS}; do
            DIRVAL="${DIR}"
            reinplace "s,${TAG}${DIR}${TAG},${!DIRVAL},g" $FILES
        done
    fi
}

function lp_clean_packages_scripts() {
    local FILES=$(grep -l "#CPKG_.*" $PKG_ROOTDIR/debian/*)

    if [ -n "$FILES" ]; then
        reinplace "s,#CPKG_.*$,,g" $FILES
    fi
}

function lp_install_local_packages() {
    sudo dpkg -i *.deb
}

function lp_install_packages() {
    sudo apt-get install $@
}

function lp_build_header_cache() {
    local CACHE=$1
    local CACHENAME=$2

    local ARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null)
    local HOST_ARCH=$(dpkg-architecture -qDEB_HOST_ARCH 2>/dev/null)

    cp_msg "building apt header cache"

    local CMD='zgrep -h "^usr/include/" /var/cache/apt/apt-file/*.gz'

    if [[ "$HOST_ARCH" = "amd64" ]]; then
        # Filter out includes from libc6-dev-i386
        CMD+=' | grep -v libc6-dev-i386'
    fi

    echo "$CACHENAME=(" > $CACHE

    eval "$CMD" | \
        sort -ur -k 1,1 | \
        sed -e "s,^usr/include/\($ARCH/\)\?\([^[:space:]]\+\)[[:space:]]\+.\+/\([^/]*\),[\2]=\3,g" \
        >> $CACHE

    echo ")" >> $CACHE
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
        cut -d ' ' -f 1 \
        > $CACHE
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

    while read PKG; do
        CPKG_PKG_MAP[$PKG]=1
    done < $CACHE
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

        for REFFILE in /var/cache/apt/apt-file/*.gz; do
            if [ $REFFILE -nt $CACHE ]; then
                BUILD=1
                break
           fi
        done
    fi

    if (($BUILD == 1)); then
        build_header_cache $CACHE "CPKG_HEADER_MAP"
    fi

    cp_msg "loading apt header cache"
    . $CACHE
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
                -e "s,: [^[:space:]]\+/pkgconfig/, ,g" \
                -e "s,:$HOST_ARCH,,g" \
            > $CACHE
    else
        touch $CACHE
    fi
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

    local PC
    local PKG

    while read PKG PC; do
        PC=${PC%.pc}

        if [[ "${CPKG_PKGCONFIG_MAP[$PKG]}" ]]; then
            CPKG_PKGCONFIG_MAP[$PKG]=" $PC"
        else
            CPKG_PKGCONFIG_MAP[$PKG]=$PC
        fi
    done < $CACHE
}

function lp_get_pkgconfig() {
    local PC=$1
    shift

    local PCPATH=$PKG_CONFIG_PATH

    env PKG_CONFIG_PATH=$PCPATH pkg-config $@ $PC
}

function lp_find_c_lib() {
    local HINT=$1

    local -a MATCHES
    local MATCH
    local LINES=$(
        apt-cache search -n "${HINT}.*dev" | \
        cut -d ' ' -f 1
    )

    local -a ITEMS

    while read PKG; do
        MATCHES+=($PKG)

        if [[ $PKG =~ ^lib${HINT}.*-dev ]]; then
            MATCH=$PKG
            break
        fi
    done <<<"$LINES"

    if [ -n "$MATCH" ]; then
        echo $MATCH
    else
        echo ${MATCHES[@]}
    fi
}
