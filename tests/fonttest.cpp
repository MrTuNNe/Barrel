// Font smoke test: checks that common Windows fonts exist as files in C:\windows\Fonts
// (engines like Unity read them directly) and that Windows font names resolve to fonts
// with the glyphs they need. Exit code 0 means everything was found.
#include <windows.h>
#include <cstdio>
#include <initializer_list>

static int failed = 0;

static void file(const wchar_t *name) {
    wchar_t path[MAX_PATH];
    GetWindowsDirectoryW(path, MAX_PATH);
    lstrcatW(path, L"\\Fonts\\");
    lstrcatW(path, name);
    bool ok = GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
    if (!ok) failed = 1;
    printf("%s file %ls\n", ok ? "OK  " : "FAIL", name);
}

static void face(HDC dc, const wchar_t *name, const wchar_t *sample) {
    HFONT font = CreateFontW(24, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, 0, 0, name);
    HGDIOBJ old = SelectObject(dc, font);
    wchar_t got[LF_FACESIZE] = L"";
    GetTextFaceW(dc, LF_FACESIZE, got);
    WORD glyphs[16];
    int n = lstrlenW(sample);
    GetGlyphIndicesW(dc, sample, n, glyphs, GGI_MARK_NONEXISTING_GLYPHS);
    bool ok = true;
    for (int i = 0; i < n; i++) ok &= glyphs[i] != 0xffff;
    if (!ok) failed = 1;
    char utf8[64];
    WideCharToMultiByte(CP_UTF8, 0, got, -1, utf8, sizeof utf8, nullptr, nullptr);
    printf("%s font %-14ls -> %s\n", ok ? "OK  " : "FAIL", name, utf8);
    SelectObject(dc, old);
    DeleteObject(font);
}

int main() {
    for (const wchar_t *f : {L"arial.ttf", L"arialbd.ttf", L"times.ttf", L"cour.ttf", L"verdana.ttf",
                             L"tahoma.ttf", L"msgothic.ttc", L"msmincho.ttc", L"meiryo.ttc", L"simsun.ttc",
                             L"msyh.ttc", L"malgun.ttf"})
        file(f);
    HDC dc = CreateCompatibleDC(nullptr);
    face(dc, L"Arial", L"Text");
    face(dc, L"Times New Roman", L"Text");
    face(dc, L"MS Gothic", L"\u65e5\u672c\u8a9e");   // 日本語
    face(dc, L"MS Mincho", L"\u65e5\u672c\u8a9e");
    face(dc, L"Meiryo", L"\u3072\u3089\u304c\u306a"); // ひらがな
    face(dc, L"Yu Gothic", L"\u30ab\u30bf\u30ab\u30ca"); // カタカナ
    face(dc, L"SimSun", L"\u4e2d\u6587");             // 中文
    face(dc, L"Microsoft YaHei", L"\u4e2d\u6587");
    face(dc, L"Malgun Gothic", L"\ud55c\uae00");      // 한글
    face(dc, L"Segoe UI", L"Text");
    DeleteDC(dc);
    return failed;
}
