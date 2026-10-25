/* fusion-box: does a destroyed child window's GPU (DXVK) frame stay on screen?
 *
 * Reproducer for patches/wine/0014. A blue toplevel window gets a red
 * D3D11-rendered child. After 3 s the child HWND is destroyed while the app
 * still holds its swapchain, which is what Fusion does with its 3D viewport
 * when you close a design. Correct: the panel disappears and the window is
 * all blue. Bug (patches 0001-0013 without 0014): the panel stays on screen.
 * (The panel may show black instead of red in a screenshot; what matters is
 * whether it disappears.)
 *
 * Build inside the container and run against the Fusion prefix (Fusion may
 * keep running; DXVK must be installed in the prefix):
 *
 *   x86_64-w64-mingw32-gcc -O1 -o child-destroy-subsurface.exe \
 *       child-destroy-subsurface.c -ld3d11 -ldxgi -lgdi32 -luuid
 *   WINEPREFIX=~/.wine-fusion WINEDLLOVERRIDES="winewayland.drv=b;winex11.drv=" \
 *       ~/wine-versions/wine-11.10-fusion/bin/wine child-destroy-subsurface.exe
 *
 * Look at the window between ~3 s and ~12 s after "destroying child window".
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

static LRESULT CALLBACK top_proc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_PAINT) {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        HBRUSH b = CreateSolidBrush(RGB(30, 60, 200));
        FillRect(dc, &ps.rcPaint, b);
        DeleteObject(b);
        EndPaint(h, &ps);
        return 0;
    }
    if (m == WM_DESTROY) PostQuitMessage(0);
    return DefWindowProcW(h, m, w, l);
}

static void pump(DWORD ms)
{
    DWORD end = GetTickCount() + ms;
    MSG msg;
    while ((LONG)(end - GetTickCount()) > 0) {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        Sleep(10);
    }
}

int main(void)
{
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = top_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"fbtop";
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    RegisterClassW(&wc);
    wc.lpfnWndProc = DefWindowProcW;
    wc.lpszClassName = L"fbchild";
    RegisterClassW(&wc);

    HWND top = CreateWindowW(L"fbtop", L"fusion-box child-destroy test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                             100, 100, 900, 700, NULL, NULL, wc.hInstance, NULL);
    HWND child = CreateWindowW(L"fbchild", L"", WS_CHILD | WS_VISIBLE, 100, 100, 600, 400, top, NULL,
                               wc.hInstance, NULL);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 2;
    sd.BufferDesc.Width = 600;
    sd.BufferDesc.Height = 400;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = child;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;

    IDXGISwapChain *sc = NULL;
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                               D3D11_SDK_VERSION, &sd, &sc, &dev, NULL, &ctx);
    printf("D3D11CreateDeviceAndSwapChain hr=%#lx\n", hr);
    fflush(stdout);
    if (FAILED(hr)) return 1;

    ID3D11Texture2D *bb = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb);
    ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv);
    const float red[4] = {0.9f, 0.1f, 0.1f, 1.0f};

    for (int i = 0; i < 90; i++) { /* ~3 s of red frames */
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, red);
        IDXGISwapChain_Present(sc, 1, 0);
        pump(1);
    }

    printf("destroying child window (swapchain still alive)\n");
    fflush(stdout);
    DestroyWindow(child);
    InvalidateRect(top, NULL, TRUE);
    pump(9000);

    printf("done\n");
    return 0;
}
