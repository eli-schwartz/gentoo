# Copyright 1999-2024 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8
PYTHON_COMPAT=( python{3_9,3_10,3_11} )

inherit autotools fcaps flag-o-matic linux-info optfeature python-single-r1 systemd toolchain-funcs

if [[ ${PV} == *9999 ]] ; then
	EGIT_REPO_URI="https://github.com/netdata/${PN}.git"
	inherit git-r3
else
	SRC_URI="https://github.com/netdata/${PN}/releases/download/v${PV}/${PN}-v${PV}.tar.gz -> ${P}.tar.gz"
	S="${WORKDIR}/${PN}-v${PV}"
	KEYWORDS="~amd64 ~arm64 ~ppc64 ~riscv ~x86"
fi

DESCRIPTION="Linux real time system monitoring, done right!"
HOMEPAGE="https://github.com/netdata/netdata https://my-netdata.io/"

LICENSE="GPL-3+ MIT BSD"
SLOT="0"
IUSE="caps cloud +compression cpu_flags_x86_sse2 cups +dbengine ipmi +jsonc +lto mongodb mysql nfacct nodejs postgres prometheus +python tor xen"
REQUIRED_USE="
	mysql? ( python )
	python? ( ${PYTHON_REQUIRED_USE} )
	tor? ( python )"

# most unconditional dependencies are for plugins.d/charts.d.plugin:
RDEPEND="
	acct-group/netdata
	acct-user/netdata
	app-misc/jq
	>=app-shells/bash-4:0
	|| (
		net-analyzer/openbsd-netcat
		net-analyzer/netcat
	)
	net-libs/libwebsockets
	net-misc/curl
	net-misc/wget
	sys-apps/util-linux
	app-alternatives/awk
	caps? ( sys-libs/libcap )
	cups? ( net-print/cups )
	dbengine? (
		app-arch/lz4:=
		dev-libs/judy
		dev-libs/openssl:=
	)
	dev-libs/libuv:=
	dev-libs/libyaml
	cloud? ( dev-libs/protobuf:= )
	sys-libs/zlib
	ipmi? ( sys-libs/freeipmi )
	jsonc? ( dev-libs/json-c:= )
	mongodb? ( dev-libs/mongo-c-driver )
	nfacct? (
		net-firewall/nfacct
		net-libs/libmnl:=
	)
	nodejs? ( net-libs/nodejs )
	prometheus? (
		app-arch/snappy:=
		dev-libs/protobuf:=
	)
	python? (
		${PYTHON_DEPS}
		$(python_gen_cond_dep 'dev-python/pyyaml[${PYTHON_USEDEP}]')
		mysql? ( $(python_gen_cond_dep 'dev-python/mysqlclient[${PYTHON_USEDEP}]') )
		postgres? ( $(python_gen_cond_dep 'dev-python/psycopg:2[${PYTHON_USEDEP}]') )
		tor? ( $(python_gen_cond_dep 'net-libs/stem[${PYTHON_USEDEP}]') )
	)
	xen? (
		app-emulation/xen-tools
		dev-libs/yajl
	)"
DEPEND="${RDEPEND}
	virtual/pkgconfig"

FILECAPS=(
	'cap_dac_read_search,cap_sys_ptrace+ep'
	'usr/libexec/netdata/plugins.d/apps.plugin'
	'usr/libexec/netdata/plugins.d/debugfs.plugin'
)

pkg_setup() {
	use python && python-single-r1_pkg_setup
	linux-info_pkg_setup
}

src_prepare() {
	default
	eautoreconf
}

src_configure() {
	if use ppc64; then
		# bundled dlib does not support vsx on big-endian
		# https://github.com/davisking/dlib/issues/397
		[[ $(tc-endian) == big ]] && append-flags -mno-vsx
	fi

	econf \
		--localstatedir="${EPREFIX}"/var \
		--with-user=netdata \
		--without-bundled-protobuf \
		$(use_enable cloud) \
		$(use_enable jsonc) \
		$(use_enable cups plugin-cups) \
		$(use_enable dbengine) \
		$(use_enable nfacct plugin-nfacct) \
		$(use_enable ipmi plugin-freeipmi) \
		--disable-exporting-kinesis \
		$(use_enable lto lto) \
		$(use_enable mongodb exporting-mongodb) \
		$(use_enable prometheus exporting-prometheus-remote-write) \
		$(use_enable xen plugin-xenstat) \
		$(use_enable cpu_flags_x86_sse2 x86-sse)
}

src_compile() {
	emake clean
	default
}

src_install() {
	default

	rm -rf "${D}/var/cache" || die

	keepdir /var/log/netdata
	fowners -Rc netdata:netdata /var/log/netdata
	keepdir /var/lib/netdata
	keepdir /var/lib/netdata/registry
	fowners -Rc netdata:netdata /var/lib/netdata

	fowners -Rc root:netdata /usr/share/${PN}

	newinitd system/openrc/init.d/netdata ${PN}
	newconfd system/openrc/conf.d/netdata ${PN}
	systemd_dounit system/systemd/netdata.service
	systemd_dounit system/systemd/netdata-updater.service
	systemd_dounit system/systemd/netdata-updater.timer
	insinto /etc/netdata
	doins system/netdata.conf
}

pkg_postinst() {
	fcaps_pkg_postinst

	if use nfacct ; then
		fcaps 'cap_net_admin' 'usr/libexec/netdata/plugins.d/nfacct.plugin'
	fi

	if use xen ; then
		fcaps 'cap_dac_override' 'usr/libexec/netdata/plugins.d/xenstat.plugin'
	fi

	if use ipmi ; then
	    fcaps 'cap_dac_override' 'usr/libexec/netdata/plugins.d/freeipmi.plugin'
	fi

	optfeature "go.d external plugin" net-analyzer/netdata-go-plugin
}
