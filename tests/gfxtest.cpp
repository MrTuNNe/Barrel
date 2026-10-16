// Renderer smoke test: draws a green triangle over a red background off-screen with
// Direct3D 9, 11 or 12, reads the centre pixel back and prints the result.
// Exit code 0 means the pixel came back green.
#include <windows.h>
#include <d3d9.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <d3dcompiler.h>
#include <cstdio>
#include <cstring>

static const char *hlsl = R"(
float4 vs(uint id : SV_VertexID) : SV_Position {
    float2 p = float2((id << 1) & 2, id & 2);
    return float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
}
float4 ps() : SV_Target { return float4(0, 1, 0, 1); }
)";

static const int N = 64;
static const float RED[4] = {1, 0, 0, 1};

static int fail(const char *what, HRESULT hr) {
    printf("FAIL %s (0x%08lx)\n", what, (unsigned long)hr);
    return 1;
}

static int report(const char *api, const char *gpu, UINT32 rgba) {
    bool green = (rgba & 0x00ffffff) == 0x0000ff00;  // R8G8B8A8 read as little-endian: 0xAABBGGRR
    printf("%s %s gpu=\"%s\" pixel=%08x\n", green ? "OK" : "FAIL", api, gpu, rgba);
    return green ? 0 : 1;
}

static HRESULT compile(const char *entry, const char *target, ID3DBlob **out) {
    ID3DBlob *err = nullptr;
    HRESULT hr = D3DCompile(hlsl, strlen(hlsl), nullptr, nullptr, nullptr, entry, target, 0, 0, out, &err);
    if (err) { printf("%s\n", (char *)err->GetBufferPointer()); err->Release(); }
    return hr;
}

static void adapter_name(IDXGIAdapter *a, char *buf) {
    DXGI_ADAPTER_DESC d{};
    a->GetDesc(&d);
    WideCharToMultiByte(CP_UTF8, 0, d.Description, -1, buf, 128, nullptr, nullptr);
}

static int test_d3d11() {
    ID3D11Device *dev; ID3D11DeviceContext *ctx;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0,
                                   D3D11_SDK_VERSION, &dev, nullptr, &ctx);
    if (FAILED(hr)) return fail("D3D11CreateDevice", hr);

    char gpu[128] = "?";
    IDXGIDevice *dxgi; IDXGIAdapter *adapter;
    if (SUCCEEDED(dev->QueryInterface(__uuidof(IDXGIDevice), (void **)&dxgi)) && SUCCEEDED(dxgi->GetAdapter(&adapter)))
        adapter_name(adapter, gpu);

    D3D11_TEXTURE2D_DESC td{N, N, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET};
    ID3D11Texture2D *rt, *staging;
    if (FAILED(hr = dev->CreateTexture2D(&td, nullptr, &rt))) return fail("CreateTexture2D", hr);
    td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(hr = dev->CreateTexture2D(&td, nullptr, &staging))) return fail("CreateTexture2D staging", hr);
    ID3D11RenderTargetView *rtv;
    if (FAILED(hr = dev->CreateRenderTargetView(rt, nullptr, &rtv))) return fail("CreateRenderTargetView", hr);

    ID3DBlob *vsb, *psb;
    if (FAILED(hr = compile("vs", "vs_5_0", &vsb)) || FAILED(hr = compile("ps", "ps_5_0", &psb))) return fail("D3DCompile", hr);
    ID3D11VertexShader *vs; ID3D11PixelShader *ps;
    if (FAILED(hr = dev->CreateVertexShader(vsb->GetBufferPointer(), vsb->GetBufferSize(), nullptr, &vs))) return fail("CreateVertexShader", hr);
    if (FAILED(hr = dev->CreatePixelShader(psb->GetBufferPointer(), psb->GetBufferSize(), nullptr, &ps))) return fail("CreatePixelShader", hr);

    D3D11_VIEWPORT vp{0, 0, N, N, 0, 1};
    ctx->OMSetRenderTargets(1, &rtv, nullptr);
    ctx->RSSetViewports(1, &vp);
    ctx->ClearRenderTargetView(rtv, RED);
    ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ctx->VSSetShader(vs, nullptr, 0);
    ctx->PSSetShader(ps, nullptr, 0);
    ctx->Draw(3, 0);
    ctx->CopyResource(staging, rt);

    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(hr = ctx->Map(staging, 0, D3D11_MAP_READ, 0, &m))) return fail("Map", hr);
    UINT32 px = ((UINT32 *)((BYTE *)m.pData + (N / 2) * m.RowPitch))[N / 2];
    ctx->Unmap(staging, 0);
    return report(sizeof(void *) == 8 ? "d3d11" : "d3d11-32bit", gpu, px);
}

static int test_d3d12() {
    IDXGIFactory4 *factory; IDXGIAdapter1 *adapter;
    HRESULT hr = CreateDXGIFactory1(__uuidof(IDXGIFactory4), (void **)&factory);
    if (FAILED(hr)) return fail("CreateDXGIFactory1", hr);
    if (FAILED(hr = factory->EnumAdapters1(0, &adapter))) return fail("EnumAdapters1", hr);
    char gpu[128] = "?";
    adapter_name(adapter, gpu);

    ID3D12Device *dev;
    if (FAILED(hr = D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), (void **)&dev)))
        return fail("D3D12CreateDevice", hr);

    D3D12_COMMAND_QUEUE_DESC qd{D3D12_COMMAND_LIST_TYPE_DIRECT};
    ID3D12CommandQueue *queue; ID3D12CommandAllocator *alloc; ID3D12GraphicsCommandList *list;
    if (FAILED(hr = dev->CreateCommandQueue(&qd, __uuidof(ID3D12CommandQueue), (void **)&queue))) return fail("CreateCommandQueue", hr);
    if (FAILED(hr = dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator), (void **)&alloc))) return fail("CreateCommandAllocator", hr);

    // Empty root signature; the vertex shader builds the triangle from SV_VertexID.
    D3D12_ROOT_SIGNATURE_DESC rsd{};
    ID3DBlob *rsb, *rserr; ID3D12RootSignature *root;
    if (FAILED(hr = D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &rsb, &rserr))) return fail("D3D12SerializeRootSignature", hr);
    if (FAILED(hr = dev->CreateRootSignature(0, rsb->GetBufferPointer(), rsb->GetBufferSize(), __uuidof(ID3D12RootSignature), (void **)&root))) return fail("CreateRootSignature", hr);

    ID3DBlob *vsb, *psb;
    if (FAILED(hr = compile("vs", "vs_5_0", &vsb)) || FAILED(hr = compile("ps", "ps_5_0", &psb))) return fail("D3DCompile", hr);
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pd{};
    pd.pRootSignature = root;
    pd.VS = {vsb->GetBufferPointer(), vsb->GetBufferSize()};
    pd.PS = {psb->GetBufferPointer(), psb->GetBufferSize()};
    pd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pd.SampleMask = UINT_MAX;
    pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pd.RasterizerState.DepthClipEnable = TRUE;
    pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pd.NumRenderTargets = 1;
    pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    pd.SampleDesc.Count = 1;
    ID3D12PipelineState *pso;
    if (FAILED(hr = dev->CreateGraphicsPipelineState(&pd, __uuidof(ID3D12PipelineState), (void **)&pso))) return fail("CreateGraphicsPipelineState", hr);

    D3D12_HEAP_PROPERTIES def{D3D12_HEAP_TYPE_DEFAULT}, rb{D3D12_HEAP_TYPE_READBACK};
    D3D12_RESOURCE_DESC td{D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, N, N, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0},
                           D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET};
    D3D12_CLEAR_VALUE cv{DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0, 0, 1}};
    ID3D12Resource *rt, *readback;
    if (FAILED(hr = dev->CreateCommittedResource(&def, D3D12_HEAP_FLAG_NONE, &td, D3D12_RESOURCE_STATE_RENDER_TARGET, &cv, __uuidof(ID3D12Resource), (void **)&rt)))
        return fail("CreateCommittedResource rt", hr);
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp; UINT64 total;
    dev->GetCopyableFootprints(&td, 0, 1, 0, &fp, nullptr, nullptr, &total);
    D3D12_RESOURCE_DESC bd{D3D12_RESOURCE_DIMENSION_BUFFER, 0, total, 1, 1, 1, DXGI_FORMAT_UNKNOWN, {1, 0}, D3D12_TEXTURE_LAYOUT_ROW_MAJOR};
    if (FAILED(hr = dev->CreateCommittedResource(&rb, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_COPY_DEST, nullptr, __uuidof(ID3D12Resource), (void **)&readback)))
        return fail("CreateCommittedResource readback", hr);

    D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1};
    ID3D12DescriptorHeap *heap;
    if (FAILED(hr = dev->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), (void **)&heap))) return fail("CreateDescriptorHeap", hr);
    D3D12_CPU_DESCRIPTOR_HANDLE rtv = heap->GetCPUDescriptorHandleForHeapStart();
    dev->CreateRenderTargetView(rt, nullptr, rtv);

    if (FAILED(hr = dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, pso, __uuidof(ID3D12GraphicsCommandList), (void **)&list)))
        return fail("CreateCommandList", hr);
    D3D12_VIEWPORT vp{0, 0, N, N, 0, 1};
    D3D12_RECT sc{0, 0, N, N};
    list->SetGraphicsRootSignature(root);
    list->RSSetViewports(1, &vp);
    list->RSSetScissorRects(1, &sc);
    list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
    list->ClearRenderTargetView(rtv, RED, 0, nullptr);
    list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    list->DrawInstanced(3, 1, 0, 0);
    D3D12_RESOURCE_BARRIER b{};
    b.Transition = {rt, 0, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE};
    list->ResourceBarrier(1, &b);
    D3D12_TEXTURE_COPY_LOCATION dst{readback, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT}, src{rt, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX};
    dst.PlacedFootprint = fp;
    src.SubresourceIndex = 0;
    list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    list->Close();
    ID3D12CommandList *lists[] = {list};
    queue->ExecuteCommandLists(1, lists);

    ID3D12Fence *fence;
    HANDLE done = CreateEventA(nullptr, FALSE, FALSE, nullptr);
    if (FAILED(hr = dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), (void **)&fence))) return fail("CreateFence", hr);
    queue->Signal(fence, 1);
    fence->SetEventOnCompletion(1, done);
    if (WaitForSingleObject(done, 10000) != WAIT_OBJECT_0) return fail("GPU timeout", E_FAIL);

    BYTE *data;
    if (FAILED(hr = readback->Map(0, nullptr, (void **)&data))) return fail("Map", hr);
    UINT32 px = ((UINT32 *)(data + fp.Offset + (N / 2) * fp.Footprint.RowPitch))[N / 2];
    readback->Unmap(0, nullptr);
    return report("d3d12", gpu, px);
}

static int test_d3d9() {
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) return fail("Direct3DCreate9", E_FAIL);
    D3DADAPTER_IDENTIFIER9 id{};
    d3d->GetAdapterIdentifier(0, 0, &id);

    // D3D9 needs a window even when drawing off-screen; this one is never shown.
    HWND wnd = CreateWindowA("STATIC", "gfxtest", WS_OVERLAPPEDWINDOW, 0, 0, N, N, nullptr, nullptr, nullptr, nullptr);
    D3DPRESENT_PARAMETERS pp{};
    pp.Windowed = TRUE; pp.SwapEffect = D3DSWAPEFFECT_DISCARD; pp.hDeviceWindow = wnd;
    pp.BackBufferWidth = N; pp.BackBufferHeight = N; pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    IDirect3DDevice9 *dev;
    HRESULT hr = d3d->CreateDevice(0, D3DDEVTYPE_HAL, wnd, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev);
    if (FAILED(hr)) return fail("CreateDevice", hr);

    IDirect3DSurface9 *rt, *sys;
    if (FAILED(hr = dev->CreateRenderTarget(N, N, D3DFMT_A8R8G8B8, D3DMULTISAMPLE_NONE, 0, FALSE, &rt, nullptr))) return fail("CreateRenderTarget", hr);
    if (FAILED(hr = dev->CreateOffscreenPlainSurface(N, N, D3DFMT_A8R8G8B8, D3DPOOL_SYSTEMMEM, &sys, nullptr))) return fail("CreateOffscreenPlainSurface", hr);
    struct V { float x, y, z, w; DWORD c; } tri[3] = {
        {0, 0, 0, 1, 0xff00ff00}, {2.0f * N, 0, 0, 1, 0xff00ff00}, {0, 2.0f * N, 0, 1, 0xff00ff00}};
    dev->SetRenderTarget(0, rt);
    dev->Clear(0, nullptr, D3DCLEAR_TARGET, 0xffff0000, 1, 0);
    dev->BeginScene();
    dev->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE);
    dev->SetRenderState(D3DRS_LIGHTING, FALSE);
    dev->SetFVF(D3DFVF_XYZRHW | D3DFVF_DIFFUSE);
    dev->DrawPrimitiveUP(D3DPT_TRIANGLELIST, 1, tri, sizeof(V));
    dev->EndScene();
    if (FAILED(hr = dev->GetRenderTargetData(rt, sys))) return fail("GetRenderTargetData", hr);
    D3DLOCKED_RECT lr;
    if (FAILED(hr = sys->LockRect(&lr, nullptr, D3DLOCK_READONLY))) return fail("LockRect", hr);
    UINT32 argb = ((UINT32 *)((BYTE *)lr.pBits + (N / 2) * lr.Pitch))[N / 2];
    sys->UnlockRect();
    // A8R8G8B8 -> the R8G8B8A8 layout report() expects.
    UINT32 rgba = (argb & 0xff00ff00) | ((argb >> 16) & 0xff) | ((argb & 0xff) << 16);
    return report("d3d9", id.Description, rgba);
}

int main(int argc, char **argv) {
    const char *api = argc > 1 ? argv[1] : "d3d11";
    if (!strcmp(api, "d3d9")) return test_d3d9();
    if (!strcmp(api, "d3d12")) return test_d3d12();
    return test_d3d11();
}
