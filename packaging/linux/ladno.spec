%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none
Name:           ladno
Version:        %{app_version}
Release:        1
Summary:        Личные заметки без облака
License:        LicenseRef-Proprietary
URL:            https://github.com/sssolyarka/ladno
BuildArch:      x86_64
AutoReqProv:    no
Requires:       gtk3, libstdc++, libX11, libXext, libglvnd-glx, sqlite-libs

Requires: libsecret
Requires: avahi

%description
Ладно — локальные заметки с папками, поиском, Markdown и резервными копиями.
Защищённая синхронизация в локальной сети, вложения и конфликты.
Для ключей подключения нужен работающий кошелёк Secret Service.

%prep
%build

%install
mkdir -p %{buildroot}/opt/ladno
cp -a %{bundle_dir}/. %{buildroot}/opt/ladno/
install -Dm644 %{project_dir}/packaging/linux/ladno.desktop %{buildroot}/usr/share/applications/ladno.desktop
install -Dm644 %{project_dir}/packaging/linux/ladno.svg %{buildroot}/usr/share/icons/hicolor/scalable/apps/ladno.svg
install -Dm644 %{project_dir}/docs/RELEASES.md %{buildroot}/usr/share/doc/ladno/RELEASES.md

%files
/opt/ladno
/usr/share/applications/ladno.desktop
/usr/share/icons/hicolor/scalable/apps/ladno.svg
/usr/share/doc/ladno/RELEASES.md
