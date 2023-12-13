# Copyright 2023 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DISTUTILS_USE_PEP517=setuptools
PYTHON_COMPAT=( pypy3 python3_{10..12} )

inherit distutils-r1

DESCRIPTION="tzdata shim to satisfy requirements (while using system tzdata)"
HOMEPAGE="https://peps.python.org/pep-0615/"

LICENSE="public-domain"
SLOT="0"
KEYWORDS="~alpha amd64 arm arm64 ~hppa ~ia64 ~loong ~m68k ~mips ~ppc ppc64 ~riscv ~s390 ~sparc x86"

RDEPEND="
	sys-libs/timezone-data
"

src_unpack() {
	mkdir "${S}" || die
	cat > "${S}/pyproject.toml" <<-EOF || die
		[build-system]
		requires = ["setuptools"]
		build-backend = "setuptools.build_meta"

		[project]
		name = "tzdata"
		version = "9999"
		description = "tzdata shim to satisfy requirements (using system tzdata)"

		[tool.setuptools]
		packages = []
	EOF
}
