# Copyright 1999-2024 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit crossdev flag-o-matic toolchain-funcs prefix

DESCRIPTION="Light, fast and, simple C library focused on standards-conformance and safety"
HOMEPAGE="https://musl.libc.org"

if [[ ${PV} == 9999 ]] ; then
	EGIT_REPO_URI="https://git.musl-libc.org/git/musl"
	inherit git-r3
else
	VERIFY_SIG_OPENPGP_KEY_PATH=/usr/share/openpgp-keys/musl.asc
	inherit verify-sig

	SRC_URI="https://musl.libc.org/releases/${P}.tar.gz"
	SRC_URI+=" verify-sig? ( https://musl.libc.org/releases/${P}.tar.gz.asc )"
	KEYWORDS="-* ~amd64 ~arm ~arm64 ~m68k ~mips ~ppc ~ppc64 ~riscv ~x86"

	BDEPEND="verify-sig? ( sec-keys/openpgp-keys-musl )"
fi

GETENT_COMMIT="93a08815f8598db442d8b766b463d0150ed8e2ab"
GETENT_FILE="musl-getent-${GETENT_COMMIT}.c"
SRC_URI+="
	https://dev.gentoo.org/~blueness/musl-misc/getconf.c
	https://gitlab.alpinelinux.org/alpine/aports/-/raw/${GETENT_COMMIT}/main/musl/getent.c -> ${GETENT_FILE}
	https://dev.gentoo.org/~blueness/musl-misc/iconv.c
"

LICENSE="MIT LGPL-2 GPL-2"
SLOT="0"
IUSE="crypt headers-only"

QA_SONAME="usr/lib/libc.so"
QA_DT_NEEDED="usr/lib/libc.so"
# bug #830213
QA_PRESTRIPPED="usr/lib/crtn.o"

# We want crypt on by default for this as sys-libs/libxcrypt isn't (yet?)
# built as part as crossdev. Also, elide the blockers when in cross-*,
# as it doesn't make sense to block the normal CBUILD libxcrypt at all
# there when we're installing into /usr/${CHOST} anyway.
if is_crosspkg ; then
	IUSE="${IUSE/crypt/+crypt}"
else
	RDEPEND="crypt? ( !sys-libs/libxcrypt[system] )"
	PDEPEND="!crypt? ( sys-libs/libxcrypt[system] )"
fi

just_headers() {
	use headers-only && target_is_not_host
}

pkg_setup() {
	if [ ${CTARGET} == ${CHOST} ] ; then
		case ${CHOST} in
			*-musl*) ;;
			*) die "Use sys-devel/crossdev to build a musl toolchain" ;;
		esac
	fi

	# Fix for bug #667126, copied from glibc ebuild:
	# make sure host make.conf doesn't pollute us
	if target_is_not_host || tc-is-cross-compiler ; then
		CHOST=${CTARGET} strip-unsupported-flags
	fi
}

src_unpack() {
	if [[ ${PV} == 9999 ]] ; then
		git-r3_src_unpack
	elif use verify-sig ; then
		# We only verify the release; not the additional (fixed, safe) files
		# we download.
		# (Seem to get IPC error on verifying in cross?)
		! target_is_not_host && verify-sig_verify_detached "${DISTDIR}"/${P}.tar.gz{,.asc}
	fi

	default
}

src_prepare() {
	default

	mkdir "${WORKDIR}"/misc || die
	cp "${DISTDIR}"/getconf.c "${WORKDIR}"/misc/getconf.c || die
	cp "${DISTDIR}/${GETENT_FILE}" "${WORKDIR}"/misc/getent.c || die
	cp "${DISTDIR}"/iconv.c "${WORKDIR}"/misc/iconv.c || die
}

src_configure() {
	strip-flags && filter-lto # Prevent issues caused by aggressive optimizations & bug #877343
	tc-getCC ${CTARGET}

	just_headers && export CC=true

	local sysroot
	target_is_not_host && sysroot=/usr/${CTARGET}
	./configure \
		--target=${CTARGET} \
		--prefix="${EPREFIX}${sysroot}/usr" \
		--syslibdir="${EPREFIX}${sysroot}/lib" \
		--disable-gcc-wrapper || die
}

src_compile() {
	emake obj/include/bits/alltypes.h
	just_headers && return 0

	emake
	if ! is_crosspkg ; then
		emake -C "${T}" getconf getent iconv \
			CC="$(tc-getCC)" \
			CFLAGS="${CFLAGS}" \
			CPPFLAGS="${CPPFLAGS}" \
			LDFLAGS="${LDFLAGS}" \
			VPATH="${WORKDIR}/misc"
	fi

	$(tc-getCC) ${CPPFLAGS} ${CFLAGS} -c -o libssp_nonshared.o "${FILESDIR}"/stack_chk_fail_local.c || die
	$(tc-getAR) -rcs libssp_nonshared.a libssp_nonshared.o || die
}

src_install() {
	local target="install"
	just_headers && target="install-headers"
	emake DESTDIR="${D}" ${target}
	just_headers && return 0

	# musl provides ldd via a sym link to its ld.so
	local sysroot=
	target_is_not_host && sysroot=/usr/${CTARGET}
	local ldso=$(basename "${ED}${sysroot}"/lib/ld-musl-*)
	dosym -r "${sysroot}/lib/${ldso}" "${sysroot}/usr/bin/ldd"

	if ! use crypt ; then
		# Allow sys-libs/libxcrypt[system] to provide it instead
		rm "${ED}/usr/include/crypt.h" || die
		rm "${ED}/usr/$(get_libdir)/libcrypt.a" || die
	fi

	if ! is_crosspkg ; then
		# Fish out of config:
		#   ARCH = ...
		#   SUBARCH = ...
		# and print $(ARCH)$(SUBARCH).
		local arch=$(awk '{ k[$1] = $3 } END { printf("%s%s", k["ARCH"], k["SUBARCH"]); }' config.mak)

		# The musl build system seems to create a symlink:
		# ${D}/lib/ld-musl-${arch}.so.1 -> /usr/lib/libc.so.1 (absolute)
		# During cross or within prefix, there's no guarantee that the host is
		# using musl so that file may not exist. And on systems without
		# merged-usr, a relative symlink isn't reliable.
		#
		# Reverse the order, and make ld.so a real file. Since libc.so is only
		# needed by the compiler, make it into a linker script.
		local ldso_name=${ED}/lib/ld-musl-${arch}.so.1
		rm "${ldso_name}" || die
		mv "${ED}"/usr/lib/libc.so "${ldso_name}" || die

		# copied from usr-ldscript.eclass
		#
		# OUTPUT_FORMAT gives hints to the linker as to what binary format
		# is referenced ... makes multilib saner
		local flags=( ${CFLAGS} ${LDFLAGS} -Wl,--verbose )
		if $(tc-getLD) --version | grep -q 'GNU gold' ; then
				# If they're using gold, manually invoke the old bfd. #487696
				local d="${T}/bfd-linker"
				mkdir -p "${d}"
				ln -sf $(type -P ${CHOST}-ld.bfd) "${d}"/ld
				flags+=( -B"${d}" )
		fi
		local output_format=$($(tc-getCC) "${flags[@]}" 2>&1 | sed -n 's/^OUTPUT_FORMAT("\([^"]*\)",.*/\1/p')
		[[ -n ${output_format} ]] && output_format="OUTPUT_FORMAT ( ${output_format} )"

		cat > "${ED}/usr/lib/libc.so" <<-END_LDSCRIPT
			/* GNU ld script
			   Since Gentoo has critical dynamic libraries in /lib, and the static versions
			   in /usr/lib, we need to have a "fake" dynamic lib in /usr/lib, otherwise we
			   run into linking problems.  This "fake" dynamic lib is a linker script that
			   redirects the linker to the real lib.  And yes, this works in the cross-
			   compiling scenario as the sysroot-ed linker will prepend the real path.

			   See bug https://bugs.gentoo.org/4411 for more info.
			 */
			${output_format}
			GROUP ( /lib/ld-musl-${arch}.so.1 )
		END_LDSCRIPT

		cp "${FILESDIR}"/ldconfig.in-r3 "${T}"/ldconfig.in || die
		sed -e "s|@@ARCH@@|${arch}|" "${T}"/ldconfig.in > "${T}"/ldconfig || die
		eprefixify "${T}"/ldconfig
		into /
		dosbin "${T}"/ldconfig
		into /usr
		dobin "${T}"/getconf
		dobin "${T}"/getent
		dobin "${T}"/iconv
		echo 'LDPATH="include ld.so.conf.d/*.conf"' > "${T}"/00musl || die
		doenvd "${T}"/00musl
	fi

	if target_is_not_host ; then
		into /usr/${CTARGET}
		dolib.a libssp_nonshared.a
	else
		dolib.a libssp_nonshared.a
	fi
}

pkg_preinst() {
	# Nothing to do if just installing headers
	just_headers && return

	# Prepare /etc/ld.so.conf.d/ for files
	mkdir -p "${EROOT}"/etc/ld.so.conf.d
}

pkg_postinst() {
	target_is_not_host && return 0

	[[ -n "${ROOT}" ]] && return 0

	ldconfig || die
}
