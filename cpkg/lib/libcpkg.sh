set -e

# Check BASH version
if [ "${BASH_VERSINFO[0]}" -ne 4 ]; then
    echo "Bash version 4 or greater is needed (you have: $BASH_VERSION)"
    exit 1
fi

shopt -s extglob

##############################################################################
#
# Public global variables
#
##############################################################################
TOPDIR=$(pwd)
export CPKG_CONF=cpkg.conf
export CPKG_CMD
export CPKG_BUILDING_MYSELF=0

declare -a COMMANDS
declare -a CMDSSPECLIST
declare -A CMDSSPECMAP
declare -A CMDSMAP
declare -A OPTSPECS=(
    [h]="HELP::this help:"
)
declare -A OPTIONS
declare -A CPKG_TEMPLATE_DIRS
declare -A CPKG_OTHER_DIRS
declare -A CPKG_PKG_MAP
declare -A CPKG_PKGCONFIG_MAP
declare -a CPKG_TMPL_PRE
declare -a PKG_DEPS
PACKAGE_VARS="PKG_VER PKG_REV PKG_NAME PKG_DATE PKG_SHORTDESC PKG_LONGDESC"
PACKAGE_DIRS=" PKG_ROOTDIR PKG_BINDIR"
PACKAGE_DIRS+=" PKG_MANDIR PKG_VARDIR PKG_LOGDIR PKG_RUNDIR"
PACKAGE_DIRS+=" PKG_ETCDIR PKG_SYSETCDIR"
PACKAGE_DIRS+=" PKG_LIBDIR PKG_SYSLIBDIR PKG_PLUGDIR"
PACKAGE_DIRS+=" PKG_SHAREDIR PKG_SYSSHAREDIR"
PACKAGE_DIRS+=" PKG_SOURCEDIR PKG_BUILDDIR PKG_STAGEDIR PKG_SUPPORTDIR"
PACKAGE_MISC="PKG_ARCH PKG_AUTHOR_NAME PKG_AUTHOR_EMAIL"
CPKG_TMPL_VARS="TOPDIR $PACKAGE_VARS $PACKAGE_DIRS $PACKAGE_MISC"
export $CPKG_TMPL_VARS PKG_CAT
VERBOSE=0

PROG=${ME:-"utility"}
PROGTAG="$PROG: "
CPKG_LIB="${BASH_SOURCE[0]}"
CPKG_LIBDIR=$(dirname $CPKG_LIB)
CPKG_ETCDIR=""

RSYNC=rsync
RSYNC_OPTS="-avq"
[ -f $ETCDIR/rsync.exclude ] && \
    RSYNC_OPTS+=" --exclude-from=$ETCDIR/rsync.exclude"
RSYNC_NO_TMPL="--exclude=*.tmpl* --exclude=*__PKG_*"

###############################################################################
#
# Init
#
###############################################################################
function cp_error() {
    echo "${PROGTAG}E: $*" >&2

    local -a CALLER

    if (($CPKG_TRACE)); then
        CALLER=($(caller))
        echo "(at ${CALLER[1]}:${CALLER[0]})" >&2
    fi

    exit 1
}

function cp_warning() {
    echo "${PROGTAG}W: $*"
}

function cp_msg() {
    echo "${PROGTAG}$*"
}

function cp_log() {
    if [ -n "$LOGDIR" -a -d "$LOGDIR" ]; then
        echo `date '+%b %e %T'` "${PROGTAG}$*" >> $LOGDIR/$ME.log

        if [ -n "$VERBOSE" -a "$VERBOSE" != "0" ]; then
            cp_msg "$*"
        fi
    else
        cp_msg "$*"
    fi
}

function cp_init() {
    export CPKG_OS=$(uname -s)
    export CPKG_PF=UNIX
    export CPKG_BIN_ARCH=$(uname -m)

    export CPKG_IS_DEB=0
    export CPKG_IS_PKGSRC=0

    case $CPKG_OS in
        Linux)
            if [ -x /usr/bin/lsb_release ]; then
                CPKG_DIST=$(/usr/bin/lsb_release -si)

                if [[ $CPKG_DIST =~ ^(Debian|Ubuntu)$ ]]; then
                    CPKG_TYPE=deb
                    CPKG_IS_DEB=1
                else
                    cp_error "$CPKG_DIST distribution is not (yet) supported"
                fi

                CPKG_CODENAME=$(/usr/bin/lsb_release -sc)
            else
                cp_error "/usr/bin/lsb_release not found"
            fi
            ;;

        Darwin)
            if [ -x /usr/bin/sw_vers ]; then
                CPKG_DIST=$(/usr/bin/sw_vers -productName)
                CPKG_DIST=${CPKG_DIST/Mac OS X/MacOSX}
                CPKG_TYPE=pkgsrc
                CPKG_IS_PKGSRC=1
                CPKG_CODENAME=$CPKG_DIST
            else
                cp_error "/usr/bin/sw_vers not found"
            fi
            ;;

        *)
            cp_error "$CPKG_OS not (yet) supported"
            ;;
    esac

    if [ -z "$CPKG_DIST" ]; then
        cp_error "your distribution is not (yet) supported"
    fi

    export CPKG_DIST CPKG_TYPE CPKG_CODENAME CPKG_PREFIX CPKG_NATIVE
    export CPKG_HOME=$HOME/.cpkg CPKG_ETCDIR

    if [ -z "$LIBCPKG_MINIMAL" ]; then
        [[ -f $CPKG_CONF ]] && . $CPKG_CONF
        . $CPKG_LIBDIR/libcpkg-utils.sh
        . $CPKG_LIBDIR/$CPKG_TYPE/sys_vars.sh

        if [[ $CPKG_LIBDIR =~ ^$CPKG_PREFIX ]]; then
            CPKG_ETCDIR=$PKG_SYSETCDIR/cpkg
        else
            CPKG_ETCDIR=$(cd $CPKG_LIBDIR/../etc && pwd)
        fi

        . $CPKG_LIBDIR/libpackage.sh
    else
        unset LIBCPKG_MINIMAL
    fi
}

function cp_make_home() {
    mkdir -p $CPKG_HOME
}

cp_init

REQUIRED="__required__"
LOCKFILE=/tmp/$ME.lock
CPKG_REINPLACE_FILE=/tmp/cpkg-reinplace.$$

##############################################################################
#
# Utility unctions
#
##############################################################################
function cp_check_conf() {
    if [[ -f $CPKG_CONF ]]; then
        PKG_DATE=`date '+%a, %d %b %Y %H:%M:%S %z'`
        cp_ensure_vars_are_set $PACKAGE_VARS
        [[ "$PKG_NAME" == "cpkg" ]] && CPKG_BUILDING_MYSELF=1
        cp_set_scm_variables

        PKG_LONGDESC="${PKG_LONGDESC/#*($'\n')/}"
        PKG_LONGDESC="${PKG_LONGDESC/%*($'\n')/}"

        PKG_SOURCEDIR=$TOPDIR/$PKG_NAME
        TMPLDIR=$SHAREDIR/templates
        PKGTMPL=$SHAREDIR/templates/package/$CPKG_TYPE
        PKG_ROOTDIR=$TOPDIR/$PKG_NAME-$PKG_VER
        PKG_STAGEDIR=$PKG_ROOTDIR/stage
        PKG_SUPPORTDIR=$PKG_ROOTDIR/support

        cp_set_package_variables
    fi
}

function cp_add_command() {
    local CMD=$1
    local HNAME=$2

    local SIZE=${#COMMANDS[@]}
    COMMANDS[$SIZE]="$CMD"
    CMDSSPECLIST[$SIZE]="$HNAME"
    CMDSMAP["$CMD"]=1
    CMDSSPECMAP["$CMD"]="$HNAME"
}

function cp_print_options() {
    local HNAME=$1

    local -A SPECS
    local -a OPTA
    local KEY FMT PAD="  " ALIGN="      "

    cp_copy_hash SPECS $HNAME

    for KEY in ${!SPECS[*]}; do
        cb_split OPTA ":" "${SPECS[${KEY}]}"

        if [ -n "${OPTA[3]}" ]; then
            if [ "${OPTA[3]}" = "$REQUIRED" ]; then
                OPTA[3]=" (required)"
            else
                OPTA[3]=" (default: ${OPTA[3]})"
            fi
        fi

        FMT="$PAD-$KEY"

        if [[ -n "${OPTA[1]}" ]]; then
            FMT+=" %s\n$PAD  $ALIGN"
        else
            FMT+="$ALIGN%s"
        fi

        FMT+="%s%s\n"

        printf "$FMT" "${OPTA[1]}" "${OPTA[2]}" "${OPTA[3]}"
    done
}

function cp_usage() {
    [ -n "$1" ] && echo -e "${PROGTAG}$1\n"

    local PSPEC="$PROG"

    ((${#OPTSPECS[*]} > 0)) && PSPEC+=" [option]..."
    ((${#COMMANDS[@]} > 0)) && PSPEC+=" command [option]..."

    printf "usage: $PSPEC\n"

    if ((${#OPTSPECS[*]} > 0)); then
        printf "\nOPTIONS\n"
        cp_print_options OPTSPECS
    fi

    local I CMD HNAME

    if ((${#COMMANDS[*]} > 0)); then
        printf "\nCOMMANDS\n"

        for ((I=0; $I < ${#COMMANDS[@]}; I++)); do
            CMD="${COMMANDS[$I]}"
            HNAME="${CMDSSPECLIST[$I]}"
            echo -e "\n  $CMD"
            [[ -n "$HNAME" ]] && cp_print_options $HNAME
        done
    fi

    printf "\n"

    exit ${2:-1}
}

function cp_make_optstring() {
    local VNAME=$1
    local HNAME=$2

    local KEY
    local -A SPECS
    local -a OPTA

    eval "${VNAME}=\"\""

    cp_copy_hash SPECS $HNAME

    for KEY in ${!SPECS[*]}; do
        cb_split OPTA ":" "${SPECS[${KEY}]}"
        eval "${VNAME}+=\"$KEY\""

        if [ -n "${OPTA[1]}" ]; then
            # Option expects an argument
            eval "${VNAME}+=\":\""
        fi
    done
}

function cp_run_getopts() {
    local HNAME=$1
    local CNAME=$2
    shift 2

    local -A SPECS
    local -a OPTA
    local OPTSTRING OPT OPTVAR

    cp_copy_hash SPECS $HNAME
    cp_make_optstring "OPTSTRING" $HNAME

    eval "${CNAME}=0"
    OPTIND=0

    # Set defaults
    for KEY in ${!SPECS[*]}; do
        cb_split OPTA ":" "${SPECS[${KEY}]}"

        if [ -n "${OPTA[3]}" ]; then
            OPTVAR="${OPTA[0]}"
            OPT="${OPTA[3]//no/0}"
            OPT="${OPT//yes/1}"
            OPTIONS[${OPTVAR}]="$OPT"
            export "${OPTVAR}"="$OPT"
        fi
    done

    while getopts "$OPTSTRING" OPT; do
        [[ "$OPT" == "?" ]] && cp_usage

        eval "((++${CNAME}))"
        cb_split OPTA ":" "${SPECS[${OPT}]}"

        if [ -z "${OPTA[1]}" ]; then
            # Provide a boolean value for flags
            OPTARG=1
        fi

        OPTVAR="${OPTA[0]}"
        OPTIONS[${OPTVAR}]="$OPTARG"
        export "${OPTVAR}"="$OPTARG"
    done

    # Check mandatory options were specified
    for KEY in ${!SPECS[*]}; do
        cb_split OPTA ":" "${SPECS[${KEY}]}"
        OPTVAR="${OPTA[0]}"
        OPTVAL=${OPTIONS[${OPTVAR}]}

        if [[ "$OPTVAL" == "$REQUIRED" ]]; then
            # Option is required and was not set
            cp_usage "missing option -$KEY"
        fi
    done
}

function cp_get_options() {
    local OPTCOUNT CMD HNAME

    # Get global options
    cp_run_getopts OPTSPECS OPTCOUNT "$@"
    shift $OPTCOUNT

    if ((${OPTIONS["HELP"]})); then
        cp_usage "" 0
    fi

    if ((${#COMMANDS[*]} > 0)); then
        # We're expecting a command
        (($#)) || cp_error "missing command"

        CMD="$1"
        [[ -n "$CMD" ]] || cp_error "missing command"
        shift

        CPKG_CMD=$CMD

        ((${CMDSMAP[$CMD]})) || cp_error "unknown command: $CMD"

        HNAME="${CMDSSPECMAP[$CMD]}"

        if [[ -n "$HNAME" ]]; then
            cp_run_getopts $HNAME OPTCOUNT "$@"
        fi
    fi
}

function cp_find_arch() {
    local ARCH="all"
    local DIR

    for DIR in bin lib; do
        if [ ! -d $PKG_SOURCEDIR/$DIR ]; then
            continue
        fi

        BIN=$(
            find $PKG_SOURCEDIR/$DIR -type f | \
            egrep -v "\.(svn|git)" | \
            xargs file | \
            egrep "ELF (32|64)-bit"
        )

        if [ -n "$BIN" ]; then
            ARCH="any"
        fi
    done

    echo $ARCH
}

function cp_delete_bootstrap() {
    if [ -d $PKG_STAGEDIR/$PKG_BINDIR ]; then
        SCRIPTS=$(
            find $PKG_STAGEDIR/$PKG_BINDIR -type f | \
            xargs grep -l "^# CPKG BOOTSTRAP"
        )

        for SCRIPT in $SCRIPTS; do
            cp_delete_block $SCRIPT "CPKG BOOTSTRAP" "#"
        done
    fi
}

function cp_set_package_variables() {
    PKG_ARCH=$(cp_find_arch)

    local S="\${PKG_DEPS_${CPKG_TYPE}[@]}"
    eval "PKG_DEPS+=(\"$S\")"

    local PKGDISTCATVAR="PKG_CATS[${CPKG_TYPE}]"
    PKG_CAT="${!PKGDISTCATVAR}"

    CPKG_OTHER_DIRS["bin"]=$PKG_BINDIR
    CPKG_OTHER_DIRS["lib"]=$PKG_LIBDIR
    CPKG_OTHER_DIRS["_lib"]=$PKG_SYSLIBDIR
    CPKG_OTHER_DIRS["share"]=$PKG_SHAREDIR
    CPKG_OTHER_DIRS["_share"]=$PKG_SYSSHAREDIR
    CPKG_OTHER_DIRS["var/lib"]=$PKG_VARDIR
    CPKG_OTHER_DIRS["var/log"]=$PKG_LOGDIR

    if (($CPKG_NATIVE == 1)); then
        CPKG_TEMPLATE_DIRS["etc"]="$PKG_STAGEDIR/etc/$PKG_NAME"
        CPKG_TEMPLATE_DIRS["_etc"]="$PKG_STAGEDIR/etc"
    else
        CPKG_TEMPLATE_DIRS["etc"]="$PKG_STAGEDIR$CPKG_PREFIX/etc/$PKG_NAME"
        CPKG_TEMPLATE_DIRS["_etc"]="$PKG_STAGEDIR$CPKG_PREFIX/etc"
    fi
}

function cp_set_git_variables() {
    URL=$(git config --local remote.origin.url)
    PKG_AUTHOR_EMAIL=$(git config user.email)
    PKG_AUTHOR_NAME=$(git config user.name)

    if [[ $URL =~ github\.com ]]; then
        export PKG_FROM_GH=1
        export PKG_GH_COMMIT=$(git log --pretty=format:'%H' -n 1)
        export PKG_GH_URL=${URL#git@github.com:}
        PKG_GH_URL=${PKG_GH_URL%\.git}
        PKG_GH_URL="https://github.com/$PKG_GH_URL"
    fi
}

function cp_set_scm_variables() {
    if [ -d $TOPDIR/.git ]; then
        cp_set_git_variables
    fi
}

function cp_has_git_uncommitted_changes() {
    local RET=1
    local LINES=$(
        git status -b --porcelain | \
        egrep "^(..\s$PKG_NAME/|##.*\[ahead)"
    )

    [[ -n "$LINES" ]] && RET=0

    return $RET
}

function cp_has_uncommitted_changes() {
    if [ -d $TOPDIR/.git ]; then
        cp_has_git_uncommitted_changes
    else
        return 1
    fi
}

function cp_get_conf_var() {
    local CONFVAR=$1
    local VALUE

    if [ -n "$CONFVAR" ]; then
        VALUE=""

        if [ -n "$CONFFILE" -a -f "$CONFFILE" ]; then
            VALUE="`egrep ^${CONFVAR}= $CONFFILE | cut -d = -f 2`"
        fi

        export "${CONFVAR}"="$VALUE"
    fi
}

function cp_reinplace_template_vars() {
    local VAR
    local VAL

    > $CPKG_REINPLACE_FILE

    for VAR in $CPKG_TMPL_VARS; do
        VAL="${!VAR}"
        VAL="${VAL//@/\\@}"
        VAL="${VAL//$'\n'/\\n}"
        echo "s@##$VAR##@$VAL@g" >> $CPKG_REINPLACE_FILE
    done

    cp_run_sedi -f $CPKG_REINPLACE_FILE $*
}

function cp_extract_block() {
    local FILE=$1
    local TO=$2
    local KEYWORD=$3
    local COMMENT=$4

    local BEGIN="$COMMENT $KEYWORD BEGIN"
    local END="$COMMENT $KEYWORD END"

    if [ -f "$FILE" ]; then
        cp_run_sed -n -e "/$BEGIN/,/$END/p" < $FILE > $TO
    else
        touch $TO
    fi
}

function cp_replace_block() {
    local FILE=$1
    local KEYWORD=$2
    local COMMENT=$3
    shift 3

    local BEGIN="$COMMENT $KEYWORD BEGIN"
    local END="$COMMENT $KEYWORD END"

    echo -e "$BEGIN\n$*\n$END" > $FILE.cpkg-new
    cp_extract_block $FILE $FILE.cpkg-old "$KEYWORD" "$COMMENT"

    local HNEW=$(cp_file_hash $FILE.cpkg-new)
    local HOLD=$(cp_file_hash $FILE.cpkg-old)

    if [ -f "$FILE" ]; then
        if [ -s $FILE.cpkg-old ]; then
            if [ "$HNEW" != "$HOLD" ]; then
                # Block exists and is different, replace
                # (we don't want to touch the file otherwise)
                cp_reinplace "/^$BEGIN$/ {
                    :eat
                    N
                    /$END/!beat
                    r $FILE.cpkg-new
                    N
                }" $FILE
            fi
        else
            # Add block
            cat $FILE.cpkg-new >> $FILE
        fi
    fi

    rm -f $FILE.cpkg-{new,old}
}

function cp_delete_block() {
    local FILE=$1
    local KEYWORD=$2
    local COMMENT=$3
    shift 3

    local BEGIN="$COMMENT $KEYWORD BEGIN"
    local END="$COMMENT $KEYWORD END"

    cp_reinplace "/^$BEGIN$/,/^$END/d" $FILE
}

function cp_replace_template_var_from_file() {
    local CONF=$1
    local VAR=$2
    local FILE=$3

    if [ -f "$CONF" ]; then
        cp_reinplace "/#${VAR}#/ {
        	r $FILE
        	d
        }" $CONF
    fi
}

function cp_wrap_script_for_phase() {
    local SCRIPT=$1
    local PHASE=$2
    local RESULT=$3
    local LINE

    echo 'if [ "$1" = "'$PHASE'" ]; then' > $RESULT

    local OLD_IFS="$IFS"
    IFS=""

    while read -r LINE; do
        echo "    $LINE" >> $RESULT
    done < $SCRIPT

    IFS="$OLD_IFS"

    echo 'fi' >> $RESULT
}

function cp_find_cmd() {
    local VARNAME=$1
    local CMD=$2
    local OPTIONAL=$3
    local BINDIR

    for BINDIR in ${PATH//:/ }; do
        if [ -x "$BINDIR/$CMD" ]; then
            export "$VARNAME"=$BINDIR/$CMD
            cp_log "using $CMD from $BINDIR/$CMD"
            return
        fi
    done

    [[ "$OPTIONAL" ]] || cp_error "$CMD not found"
}

function cp_process_template() {
    local FROM=$1
    local TO=$2
    local TVAR=$3
    local TVAL=$4

    if [ -z "$FROM" -o ! -f "$FROM" ]; then
        cp_error "invalid or missing template: $FROM"
    fi

    if [ -z "$TO" ]; then
        TO=$FROM
    fi

    # Check if template is applicable for OS/DIST
    if [[ $FROM =~ \.tmpl ]]; then
        if ! [[ $FROM =~ \.tmpl(\.$CPKG_OS)?(\.$CPKG_DIST)?$ ]]; then
            # Not applicable for OS/DIST
            return 0
        fi
    else
        # Not a template
        return 0
    fi

    local TMPL="/tmp/cpkg-${FROM////_}.$$"
    local INSHBLOCK=0 INBLOCK=0 LINENUM=0
    declare -a INLINES
    local INLINE IDX BEFORE REST

    # Set process_templates (parent function) current template options
    echo "#\!$SHELL" > $TMPL
    echo 'set -e' >> $TMPL
    echo "OPTFILE=$TMPL.opts" >> $TMPL
    echo 'declare -A OPTS' >> $TMPL
    echo 'OPTS["process"]=1' >> $TMPL

    if [ -n "$TVAR" ]; then
        echo "$TVAR=\"${TVAL}\"" >> $TMPL
    fi

    echo ". $CPKG_LIBDIR/libcpkg-utils.sh" >> $TMPL

    if ((${#CPKG_TMPL_PRE[@]})); then
        local PRE

        for PRE in "${CPKG_TMPL_PRE[@]}"; do
            if [ -f "$PRE" ]; then
                echo ". $PRE" >> $TMPL
            else
                echo "$PRE" >> $TMPL
            fi
        done
    fi

    local OLD_IFS="$IFS"
    IFS=""

    while read -r LINE; do
        LINENUM=$(($LINENUM + 1))

        if [[ "$LINE" =~ ^%\{Bash\}% ]]; then
            # Verbatim bash block begin
            if (($INSHBLOCK)); then
                cp_error "line $LINENUM: unclosed previous block"
            else
                INSHBLOCK=1
            fi

            continue
        elif [[ "$LINE" =~ ^%\{/Bash\}% ]]; then
            # Verbatim bash block end
            if ((!$INSHBLOCK)); then
                cp_error "line $LINENUM: no previous opened block"
            else
                INSHBLOCK=0
            fi

            continue
        elif (($INSHBLOCK)); then
            echo "$LINE" >> $TMPL
            continue
        elif [[ "$LINE" =~ ^%[[:space:]]*$ ]]; then
            # Skip empty lines
            continue
        elif ! [[ "$LINE" =~ ^%[[:space:]]+ ]]; then
            if ((!$INBLOCK)); then
                # Start of block
                INBLOCK=1
                echo 'cat <<___CPKG_BLOCK_END___' >> $TMPL
            fi

            INLINES=()

            # Replace inlines
            while [[ "$LINE" =~ (.*)%\{[[:space:]]+(.*) ]]; do
                BEFORE="${BASH_REMATCH[1]}"
                REST="${BASH_REMATCH[2]}"

                if [[ "$REST" =~ (.*)[[:space:]]+\}%(.*) ]]; then
                    INLINE="${BASH_REMATCH[1]}"
                    REST="${BASH_REMATCH[2]}"
                    IDX=${#INLINES[*]}
                    INLINES+=("$INLINE")
                    LINE="${BEFORE}__INLINE_${IDX}__${REST}"
                else
                    cp_error "unmatched inline in: $LINE"
                fi
            done

            # Escape text line
            LINE="${LINE//\\/\\\\}"
            LINE="${LINE//\`/\\\`}"
            LINE="${LINE//\$/\\\$}"

            for ((IDX = 0; $IDX < ${#INLINES[*]}; IDX++)); do
                LINE="${LINE/__INLINE_${IDX}__/${INLINES[$IDX]}}"
            done
        else
            if (($INBLOCK)); then
                # Close previous block
                INBLOCK=0
                echo '___CPKG_BLOCK_END___' >> $TMPL
            fi

            LINE="${LINE#%}"
            LINE="${LINE# }"
        fi

        echo "$LINE" >> $TMPL
    done < $FROM

    IFS="$OLD_IFS"

    if (($INBLOCK)); then
        # Close previous block
        INBLOCK=0
        echo '___CPKG_BLOCK_END___' >> $TMPL
    fi

    # Collect options at end of template
    echo '
echo "declare -A TOPTS=(" > $OPTFILE
for OKEY in ${!OPTS[@]}; do
    echo "[$OKEY]=\"${OPTS[$OKEY]}\"" >> $OPTFILE
done
echo ")" >> $OPTFILE' >> $TMPL

    chmod +x $TMPL

    if $TMPL >$TMPL.result 2>$TMPL.log; then
        # Template ran successfully
        rm -f $TMPL $TMPL.log
    else
        cp_error \
            "template $FROM failed: consult $TMPL and $TMPL.log for details"
    fi

    cp_reinplace_template_vars $TMPL.result

    # Source template options
    . $TMPL.opts
    rm -rf $TMPL.opts

    # Test for exclusion
    if ((${TOPTS["process"]} == 0)); then
        rm -f $TMPL $TMPL.result
        return 0
    fi

    local TODIR REN VAR

    TO=${TO%.tmpl*}
    TODIR=$(dirname $TO)

    if [[ ${TOPTS["rename-to"]} ]]; then
        REN=${TOPTS["rename-to"]}

        if [[ $REN =~ ^/ ]]; then
            # Absolute path name
            TO=$REN
        else
            TO=$TODIR/$REN
        fi
    fi

    # Templatize template name...
    for VAR in $CPKG_TMPL_VARS; do
        TO=${TO//__${VAR}__/${!VAR}}
    done

    TODIR=$(dirname $TO)
    mkdir -p $TODIR

    # Process template flags
    if [[ ${TOPTS["append"]} ]]; then
        cat $TMPL.result >> $TO
    elif [[ ${TOPTS["skip-if-exists"]} ]]; then
        if [[ ! -e $TO ]]; then
            mv $TMPL.result $TO
        fi
    elif [[ ${TOPTS["conf-block"]} ]]; then
        local -a BOPTS

        read -a BOPTS <<<${TOPTS["conf-block"]}

        if ((${#BOPTS[@]} != 2)); then
            cp_error "conf-block option requires keyword and comment: $FROM"
        fi

        cp_replace_block \
            $TO \
            "${BOPTS[0]}" "${BOPTS[1]}" \
            "$(cat $TMPL.result)"
    else
        local FHASH=$(cp_file_hash $TMPL.result)
        local THASH=$(cp_file_hash $TO)

        if [ -z "$FASH" -o "$FHASH" != "$THASH" ]; then
            mv $TMPL.result $TO
        fi
    fi

    [ -f $TMPL.result ] && rm -f $TMPL.result

    if [[ ${TOPTS["recall-foreach"]} ]]; then
        rm -f $TO
        local -a RECALL=(${TOPTS["recall-foreach"]})
        local RECALL_VAR=${RECALL[0]}
        local -a RECALL_VALUES=(${RECALL[@]:1})
        local RVAL
        local CPKG_TMPL_SILENT=1

        if [[ ${TOPTS["label"]} ]]; then
            echo -n ${TOPTS["label"]}
            cp_spinner
        fi

        for RVAL in ${RECALL_VALUES[@]}; do
            cp_process_template $FROM $TO $RECALL_VAR "$RVAL"
            cp_spinner
        done

        if [[ ${TOPTS["label"]} ]]; then
            cp_end_spinner
        fi

        return 0
    elif [[ ${TOPTS["chmod"]} ]]; then
        chmod ${TOPTS["chmod"]} $TO
    fi

    local PRETTYTO=$TO

    if [ -n "$TOPDIR" ]; then
        PRETTYTO=${TO#$TOPDIR/}
    fi

    if [[ ! $CPKG_TMPL_SILENT ]]; then
        cp_log "processed $PRETTYTO"
    fi
}

function cp_process_templates() {
    local FROMDIR=$1
    local TODIR=$2

    if [ -z "$FROMDIR" ]; then
        cp_error "invalid or missing template source directory: $FROMDIR"
    fi

    if [ ! -d "$FROMDIR" ]; then
        cp_warning "skipping template source directory: $FROMDIR"
        return
    fi

    if [ -n "$TODIR" ]; then
        TODIR+="/"
    fi

    local TEMPLATES=$(
        find $FROMDIR -type f -name \*.tmpl\* | \
        egrep -v "\.(svn|git)"
    )
    local TEMPLATE

    for TEMPLATE in $TEMPLATES; do
        cp_process_template $TEMPLATE $TODIR${TEMPLATE#$FROMDIR/}
    done
}

function cp_ensure_vars_are_set() {
    local VAR

    for VAR in $*; do
        [ -n "${!VAR}" ] || cp_error "variable '$VAR' not configured"
    done
}

function cp_ensure_file_exists() {
    [ -f "$1" ] || cp_error "missing file: $1"
}

function cp_ensure_dir_exists() {
    [ -d "$1" ] || cp_error "missing directory: $1"
}

function cp_ensure_dir_is_writable() {
    local DIR=${1%/}
    local DIRNAME=$DIR
    [[ -z "$DIRNAME" ]] && DIRNAME="/"

    local ERR=0

    if [ ! -d "$DIRNAME" ]; then
        if ! mkdir -p $DIRNAME 2>/dev/null; then
            ERR=1
        fi
    fi

    if ((!$ERR)); then
        if ! touch $DIR/.cpkg_is_writable 2>/dev/null; then
            ERR=1
        fi
    fi

    rm $DIR/.cpkg_is_writable 2>/dev/null || true
    (($ERR)) && cp_error "unsufficient permissions to write to $DIRNAME"

    return 0
}

function cp_ensure_i_am_root() {
    local USERID=`id -u`
    [ "$USERID" -eq 0 ] || cp_error "you are not root"
}

function cp_ensure_user_doesnt_exists() {
    id $1 >/dev/null 2>&1 && cp_error "user $1 already exists" || true
}

function cp_ensure_i_am_alone() {
    local OTHERPID

    while :; do
        if lockfile -1 -r 0 $LOCKFILE 2>/dev/null; then
            # Locked, remove lockfile on exit
            trap 'rm -f ${LOCKFILE}*' 0
            echo "$$" >"${LOCKFILE}.pid"
            trap 'cp_log "killed"; exit' 1 2 3 15
            break
        else
            # Lock failed, now check if the other PID is alive
            OTHERPID="$(cat "${LOCKFILE}.pid")"

            if [ $? != 0 ]; then
                cp_log "lock failed, PID ${OTHERPID} is active"
                exit 1
            fi

            if ! kill -0 $OTHERPID 2>/dev/null; then
                # Lock is stale, remove it and restart
                cp_log "removing stale lock of nonexistant PID ${OTHERPID}"
                rm -f "${LOCKFILE}*"
                cp_log "re-locking"
                continue
            else
                # Lock is valid and OTHERPID is active - exit, we're locked!
                cp_log "lock failed, PID ${OTHERPID} is active"
                exit 1
            fi
        fi
    done
}

function cp_man_section() {
    local MANPAGE=$1

    local MANSECT=1

    if [[ $MANPAGE =~ \.([[:digit:]][a-z]*)$ ]]; then
        MANSECT=${BASH_REMATCH[1]}
    fi

    echo $MANSECT
}

function cp_ask_for_install() {
    local LABEL=$1
    local PKG=$2

    echo -e "\n****\n$LABEL\n"
    local CHOICE
    local INSTALL=0

    while :; do
        read -p "Install [Y/n]? " CHOICE
        CHOICE=${CHOICE,,}

        case "$CHOICE" in
            ""|"y")
                INSTALL=1
                break
                ;;
            "n")
                INSTALL=0
                break
                ;;
        esac
    done

    echo ""

    if (($INSTALL)); then
        lp_install_packages $PKG
        return 0
    fi

    return 1
}

function cp_choose() {
    local LABEL=$1
    local PROMPT=$2
    shift 2

    if (($# == 0)); then
        return 0
    fi

    local CHOICES="1"

    if (($CHOICES > 1)); then
        CHOICES+="-$#"
    fi

    CHOICES+=", 0=Skip"

    echo -e "\n****\n$LABEL\n"
    local OLD_PS3=$PS3
    PS3="$PROMPT [$CHOICES]? "

    local CHOICE

    select CHOICE; do
        if [[ "$CHOICE" || "$REPLY" == "0" ]]; then
            break
        fi
    done

    echo ""

    PS3=$OLD_PS3

    CPKG_CHOICE=$CHOICE
}

function cp_run_support_modules() {
    local SUPPORT_DIR=$SHAREDIR/support

    [ -d $SUPPORT_DIR ] || return 0

    local MODULES=$(
        find $SUPPORT_DIR -maxdepth 1 -mindepth 1 -type d | \
        egrep -v "\.(svn|git)"
    )
    local MODULE
    local MODULE_NAME
    local NEEDED
    local PHASE

    for MODULE in $MODULES; do
        MODULE_NAME=$(basename $MODULE)

        NEEDED=1

        if [ -x $MODULE/scripts/am_i_needed.sh ]; then
            if ! $MODULE/scripts/am_i_needed.sh; then
                NEEDED=0
            fi
        fi

        if [ $NEEDED -eq 0 ]; then
            continue
        fi

        cp_log "running support module $MODULE_NAME"

        for PHASE in configure build stage; do
            if [ -x $MODULE/scripts/$PHASE.sh ]; then
                $MODULE/scripts/$PHASE.sh
            fi
        done

        for TEMPLATE_DIR in ${!CPKG_TEMPLATE_DIRS[@]}; do
            if [ -d $MODULE/$TEMPLATE_DIR ]; then
                cp_log "copying $MODULE_NAME support module $TEMPLATE_DIR"
                mkdir -p $PKG_SUPPORTDIR/$TEMPLATE_DIR
                $RSYNC \
                    $RSYNC_OPTS \
                    $MODULE/$TEMPLATE_DIR/ $PKG_SUPPORTDIR/$TEMPLATE_DIR/
            fi
        done
    done
}
