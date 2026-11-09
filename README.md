# Ладно

Личное приложение на русском для Fedora Linux, **Windows 10 x64** и Android. Общая кодовая база Flutter/Dart. Это **первый рабочий этап**, а не готовая замена SingularityApp.

## Установщики

Готовые установщики **v0.1.0 уже опубликованы**: [Fedora RPM](https://github.com/sssolyarka/ladno/releases/download/v0.1.0/ladno-0.1.0-fedora-x86_64.rpm), [Windows 10/11 Setup](https://github.com/sssolyarka/ladno/releases/download/v0.1.0/ladno-0.1.0-windows-x64-setup.exe), [Android APK](https://github.com/sssolyarka/ladno/releases/download/v0.1.0/ladno-0.1.0-android.apk). [Все файлы и контрольные суммы](https://github.com/sssolyarka/ladno/releases/tag/v0.1.0). [Как установить и выпустить обновление](docs/RELEASES.md). Состояние конкретного выпуска смотрите в Releases и Actions.

## Что уже работает

- Локальные заметки в SQLite, сохранение каждого изменения, поиск по заголовкам и тексту с русским регистром.
- Папки, перенос заметок между папками, закрепление, корзина и восстановление.
- Markdown: панель вставки форматирования и отдельный предпросмотр; до 30 предыдущих редакций.
- Светлая, тёмная и системная темы, настольные панели с изменяемой шириной, мобильные экраны и нижняя навигация.
- Ручная полная копия `.ladno`, проверка формата и SHA-256, транзакционное восстановление с подтверждением и предварительной копией.
- Экспорт Markdown и JSON, ежедневная копия на ПК при работающем приложении, хранение семи автоматических файлов.
- Ctrl+N, Ctrl+F, Ctrl+S. Без аккаунтов, серверов, демоданных и сетевых запросов из приложения.

**Не реализованы:** синхронизация, связывание, вложения, теги, ссылки между заметками, задачи, уведомления, календарь, канбан, привычки, фокус, запросы к DeepSeek. Соответствующие разделы честно показывают этап реализации. «Входящие» пока показывает все активные заметки, а не задачи. Ссылки в предпросмотре копируются в буфер, изображения не загружаются.

## Быстрый запуск на Fedora

Здесь Flutter загружен в `.tooling/flutter` (служебная папка, не часть исходников). Если используете другую машину, установите Flutter stable по [официальной инструкции](https://docs.flutter.dev/install/manual).

Проверьте инструменты и библиотеки. Установка системных пакетов требует прав администратора:

```bash
sudo dnf install clang cmake ninja-build pkgconf-pkg-config gtk3-devel libstdc++-devel sqlite-devel
```

Далее из корня проекта:

```bash
export PATH="$PWD/.tooling/flutter/bin:$PATH"
flutter doctor -v
flutter pub get
dart analyze lib test
flutter test
flutter run -d linux
```

Первая сборка требует интернета для загрузки зависимостей. Работа готового приложения — нет. Зависимости зафиксированы в `pubspec.lock`; версия инструментов указана в `docs/VERIFICATION.md`.

Сборка готовой папки приложения:

```bash
flutter build linux --release
./build/linux/x64/release/bundle/ladno
```

Можно перенести **всю папку `bundle`**, а не один исполняемый файл. Не переносите рабочую SQLite между запущенными приложениями. Для переноса данных используйте копию через настройки.

## Windows 10 x64

Нужен Windows-компьютер, Flutter stable и Visual Studio 2022 с компонентом **Desktop development with C++**, Windows SDK и CMake. Visual Studio Code не заменяет эти инструменты. См. [официальную настройку](https://docs.flutter.dev/platform-integration/windows/setup).

В PowerShell из папки исходников:

```powershell
flutter doctor -v
flutter pub get
dart analyze lib test
flutter test test/store_test.dart
flutter build windows --release
.\build\windows\x64\runner\Release\ladno.exe
```

Скопируйте **весь каталог Release** в выбранную папку и создайте ярлык на `ladno.exe`. На чистой системе может потребоваться Microsoft Visual C++ Redistributable x64. Сценарий EXE-установщика находится в packaging/windows; MSIX, Authenticode-подпись и автообновление пока не подготовлены. На Fedora Windows-бинарник не собирается; проверку на реальной Windows 10 ещё необходимо провести.

## Android

Установите Android Studio, Android SDK и Command-line Tools по [официальной инструкции Flutter](https://docs.flutter.dev/platform-integration/android/setup). Используйте JDK Android Studio. Затем:

```bash
flutter doctor --android-licenses
flutter doctor -v
flutter devices
flutter run -d DEVICE_ID
flutter build apk --debug
```

APK: `build/app/outputs/flutter-apk/app-debug.apk`. Установите на собственный телефон (разрешив установку из выбранного источника) или через `adb install -r build/app/outputs/flutter-apk/app-debug.apk`. Это отладочная сборка; она не подходит для публикации. Для выпуска нужен собственный keystore и настройка release signing по [документации](https://docs.flutter.dev/deployment/android). Release-сборка требует постоянного ключа и android/key.properties; без них она намеренно прекращается. GitHub Actions восстанавливает ключ из Secrets.

Минимальную версию Android задаёт установленный Flutter в `android/app/build.gradle.kts`; актуальная ветка требует Android API 24+. Не удаляйте приложение без экспорта: Android удалит его локальные данные. Системное облачное резервирование отключено через `android:allowBackup="false"`.

## Использование

«Новая заметка» создаёт пустую запись. Пишите заголовок и текст; статус «Сохранено локально» появляется после успешной записи в SQLite. Значок глаза переключает предпросмотр Markdown. Меню справа позволяет закрепить заметку, открыть историю или убрать в корзину. В корзине редактирование отключено, доступно восстановление. История хранит предыдущие версии заголовка и текста, а не все метаданные.

Папки создаются кнопкой «+» возле «Мои папки». На телефоне папки и остальные разделы доступны через боковое меню. Удаление папки оставляет заметки без папки. В настройках находятся темы, экспорт и восстановление.

На мобильном `Назад` из редактора возвращает к списку. Переключение заметки и навигация ожидают очередь сохранения. При ошибке записи интерфейс не должен показывать успешное сохранение; повторите Ctrl+S или исправьте причину ошибки. При аварийном уничтожении процесса последняя ещё не подтверждённая запись может не успеть сохраниться: ориентируйтесь на статус.

## Подключение устройств

В этом этапе **устройства не подключаются и не синхронизируются**. Каждая установка самостоятельна. Передача `.ladno` вручную заменяет данные и не объединяет изменения. Не используйте её как двустороннюю синхронизацию.

См. [архитектуру и проект протокола](docs/ARCHITECTURE.md), [резервные копии](docs/BACKUPS.md), [ограничения и этапы](docs/ROADMAP.md), [проверки](docs/VERIFICATION.md).

## Готовые файлы этого этапа

`dist/ladno-fedora-x64/ladno` — готовое приложение Fedora (соседние `lib` и `data` обязательны). `dist/ladno-fedora-x64.tar.gz` — та же папка в архиве. `dist/ladno-source.zip` — исходники без SDK и локальных данных. Статус проверок — в `docs/VERIFICATION.md`.
