/* Set the Windows light/dark app theme in the wineprefix and tell running programs.
 *
 * Usage: wine color-scheme.exe light|dark
 *
 * Fusion's "Match OS" UI theme reads AppsUseLightTheme, and Qt re-reads it when it
 * receives WM_SETTINGCHANGE "ImmersiveColorSet" (what Windows broadcasts when the user
 * flips the theme in Settings). launch-fusion.sh builds this with mingw and calls it
 * whenever the desktop's color-scheme changes.
 */
#include <windows.h>
#include <string.h>

int main(int argc, char **argv)
{
    static const WCHAR key[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
    DWORD light;

    if (argc != 2 || (strcmp(argv[1], "light") && strcmp(argv[1], "dark")))
        return 2;
    light = strcmp(argv[1], "light") == 0;

    if (RegSetKeyValueW(HKEY_CURRENT_USER, key, L"AppsUseLightTheme", REG_DWORD, &light, sizeof(light)) ||
        RegSetKeyValueW(HKEY_CURRENT_USER, key, L"SystemUsesLightTheme", REG_DWORD, &light, sizeof(light)))
        return 1;

    SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0, (LPARAM)L"ImmersiveColorSet",
                        SMTO_ABORTIFHUNG, 2000, NULL);
    return 0;
}
