##############################################################################
#
# pkgsrc+pkgin specific package building
#
##############################################################################
function lp_init() {
    [ -z "$PKGSRC_DIR" ] && cp_error "PKGSRC_DIR is not configured"
    [ -e "$PKGSRC_DIR" -a -f "$PKGSRC_DIR/mk/bsd.pkg.mk" ] || \
        cp_error "$PKGSRC_DIR is not a valid pkgsrc source directory"

    export PKGSRC_DIR
}

function lp_prepare_package_directory() {
    return
}

function lp_handle_manpage() {
    local MANPAGE=$1
    local MANSECT=$2
    local MANDIR=$PKG_STAGEDIR/$PKG_MANDIR/man$MANSECT

    mkdir -p $MANDIR
    mv $PKG_ROOTDIR/$MANPAGE $MANDIR
}

function lp_handle_system_file() {
    local FILE=$1
    local TYPE=$2

    return
}

function lp_handle_package_files() {
    # pkgsrc wants etc/ to be handled via it CONF_FILES framework

    if [[ -d $PKG_STAGEDIR/$PKG_SYSETCDIR ]]; then
        mkdir -p $PKG_STAGEDIR/$PKG_SHAREDIR
        mv $PKG_STAGEDIR/$PKG_SYSETCDIR $PKG_STAGEDIR/$PKG_SHAREDIR/etc
    fi
}

function lp_clean_packages_scripts() {
    return
}

function lp_install_local_packages() {
    sudo pkg_add *.tgz
}

function lp_install_packages() {
    sudo pkgin install $@
}

function lp_configure_package() {
    if (($PKGSRC_UPDATE)); then
        if cp_has_uncommitted_changes; then
            cp_error "cannot update with uncommited changes"
        fi
    fi
}

function lp_build_package() {
    local DIR=$PKGSRC_DIR/$PKG_CAT/$PKG_NAME

    [[ -d "$DIR" ]] || cp_error "invalid package directory: $DIR"

    cd $DIR
    sudo bmake distclean fetch mdi
    sudo bmake
    sudo bmake stage-install CHECK_FILES=no
    sudo bmake print-PLIST > PLIST
    pkglint
    sudo bmake clean package
}

function lp_make_pkg_map() {
    local -a PKGS=($(pkgin list | cut -d ' ' -f 1))
    local PKG

    for PKG in ${PKGS[@]}; do
        CPKG_PKG_MAP[$PKG]=1
    done
}

function make_pkg_providers_cache() {
    local DIR=$1
    local CACHE=$2
    local EXPR=$3

    local PKG

    pkg_info -aL | \
        egrep "^Information|$DIR/$EXPR" | \
        sed \
            -e "s,$DIR/,,g" \
            -e "s,Information for,PACKAGE,g" \
        > $CACHE.tmp

    while read LINE; do
        if [[ "$LINE" =~ ^PACKAGE[[:space:]]+(.*):$ ]]; then
            PKG="${BASH_REMATCH[1]}"
        else
            echo "$LINE $PKG"
        fi
    done < $CACHE.tmp > $CACHE

    rm -f $CACHE.tmp
}

function build_header_cache() {
    local CACHE=$1
    local CACHENAME=$2

    cp_msg "building pkgsrc header cache"

    local CMD='pkgin sef "^/usr/pkg/include"'

    echo "$CACHENAME=(" > $CACHE

    eval "$CMD" | \
        sed -E -e "s,^([^:]+): /usr/pkg/include/(.*),[\2]=\1,g" \
        >> $CACHE

    echo ")" >> $CACHE
}

function lp_make_pkg_header_map() {
    cp_make_home

    local CACHE=$CPKG_HOME/headers.cache
    local REFFILE=/var/db/pkgin/pkgin.db
    local BUILD=0

    if [ ! -f $CACHE ]; then
        BUILD=1
    elif [ $REFFILE -nt $CACHE ]; then
        BUILD=1
    fi

    if (($BUILD == 1)); then
        build_header_cache $CACHE "CPKG_HEADER_MAP"
    fi

    cp_msg "loading pkgsrc header cache"
    . $CACHE
}

function build_pkgconfig_cache() {
    local CACHE=$1

    cp_msg "building pkgsrc pkg-config cache"
    make_pkg_providers_cache "/usr/pkg/lib/pkgconfig" $CACHE ".*\.pc"
}

function lp_make_pkgconfig_map() {
    cp_make_home

    local CACHE=$CPKG_HOME/pkgconfig.cache
    local REFFILE=/var/db/pkgin/pkgin.db
    local BUILD=0

    if [ ! -f $CACHE ]; then
        BUILD=1
    elif [ $REFFILE -nt $CACHE ]; then
        BUILD=1
    fi

    if (($BUILD == 1)); then
        build_pkgconfig_cache $CACHE
    fi

    local PC
    local PKG

    while read PC PKG; do
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

    if [ -n "$PCPATH" ]; then
        PCPATH+=":/usr/pkg/lib/pkgconfig"
    else
        PCPATH="/usr/pkg/lib/pkgconfig"
    fi

    env PKG_CONFIG_PATH=$PCPATH pkg-config $@ $PC
}

function lp_find_c_lib() {
    local HINT=$1

    local -a MATCHES
    local MATCH
    local LINES=$(
        pkgin search $HINT | \
        egrep "^[a-zA-Z]" | \
        egrep -v "^No results found" | \
        cut -d ' ' -f 1
    )

    local -a ITEMS

    while read PKG; do
        MATCHES+=($PKG)

        if [[ $PKG == $HINT ]]; then
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
