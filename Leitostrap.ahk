#Requires AutoHotkey v2.0
#SingleInstance Force

ListLines(false)
ProcessSetPriority("High")
SetKeyDelay(-1, -1)
SetMouseDelay(-1)
SetWinDelay(-1)
SetControlDelay(-1)
SetDefaultMouseSpeed(0)

GlobalOffsets := Map()
RobloxID := 0
PersistentMode := false
MaxIntValue := 2147483647
MinIntValue := -2147483648
ReapplyTimerActive := false
ReapplyInterval := 1000
InjectedFlagsMap := Map()

class Core {
    static hProcess := 0
    static pid := 0
    static baseAddr := 0
    static ntdll := 0
    static k32 := 0

    static Init(targetPID) {
        if (this.hProcess) {
            DllCall("CloseHandle", "Ptr", this.hProcess)
            this.hProcess := 0
        }
        this.ntdll := DllCall("GetModuleHandle", "Str", "ntdll.dll", "Ptr")
        this.k32 := DllCall("GetModuleHandle", "Str", "kernel32.dll", "Ptr")
        this.pid := targetPID
        this.hProcess := DllCall("OpenProcess", "UInt", 0x1F0FFF, "Int", 0, "UInt", targetPID, "Ptr")
        if (!this.hProcess)
            return false
        this.baseAddr := this.FindBase(targetPID, "RobloxPlayerBeta.exe")
        return (this.baseAddr != 0)
    }

    static SuspendProcess() {
        if (!this.hProcess)
            return false
        addr := DllCall("GetProcAddress", "Ptr", this.ntdll, "AStr", "NtSuspendProcess", "Ptr")
        if (!addr)
            return false
        result := DllCall(addr, "Ptr", this.hProcess, "Int")
        return (result >= 0)
    }

    static ResumeProcess() {
        if (!this.hProcess)
            return false
        addr := DllCall("GetProcAddress", "Ptr", this.ntdll, "AStr", "NtResumeProcess", "Ptr")
        if (!addr)
            return false
        result := DllCall(addr, "Ptr", this.hProcess, "Int")
        return (result >= 0)
    }

    static FindBase(targetPID, moduleName) {
        snap := DllCall("CreateToolhelp32Snapshot", "UInt", 0x08, "UInt", targetPID, "Ptr")
        size := (A_PtrSize = 8) ? 1064 : 548
        modEntry := Buffer(size, 0)
        NumPut("UInt", size, modEntry, 0)
        if DllCall("Module32First", "Ptr", snap, "Ptr", modEntry) {
            loop {
                nOffset := (A_PtrSize = 8) ? 48 : 32
                bOffset := (A_PtrSize = 8) ? 24 : 20
                if (StrGet(modEntry.ptr + nOffset, "UTF-8") = moduleName) {
                    base := NumGet(modEntry.ptr + bOffset, "Ptr")
                    DllCall("CloseHandle", "Ptr", snap)
                    return base
                }
                if !DllCall("Module32Next", "Ptr", snap, "Ptr", modEntry)
                    break
            }
        }
        DllCall("CloseHandle", "Ptr", snap)
        return 0
    }

    static NtWriteMem(address, dataBuf, size) {
        if (!this.hProcess || !address)
            return false
        iosb := Buffer(16, 0)
        addr := DllCall("GetProcAddress", "Ptr", this.ntdll, "AStr", "NtWriteVirtualMemory", "Ptr")
        if (!addr)
            return false
        status := DllCall(addr, "Ptr", this.hProcess, "Ptr", address, "Ptr", dataBuf.Ptr, "UInt", size, "Ptr", iosb.Ptr, "Int")
        return (status = 0)
    }

    static NtFlushCache(address, size) {
        if (!this.hProcess || !address)
            return false
        addr := DllCall("GetProcAddress", "Ptr", this.ntdll, "AStr", "NtFlushInstructionCache", "Ptr")
        if (!addr)
            return false
        status := DllCall(addr, "Ptr", this.hProcess, "Ptr", address, "UInt", size, "Int")
        return (status = 0)
    }

    static WriteMemory(address, val, dataType) {
        if (!this.hProcess || !address)
            return false
        try {
            dataBuf := Buffer(16, 0)
            dataSize := 0
            if (dataType = "bool") {
                v := (StrLower(String(val)) = "true" || val = "1") ? 1 : 0
                NumPut("UChar", v, dataBuf)
                dataSize := 1
            } else if (dataType = "int") {
                numVal := 0
                try numVal := Integer(val)
                numVal := Max(MinIntValue, Min(MaxIntValue, numVal))
                NumPut("Int", numVal, dataBuf)
                dataSize := 4
            } else if (dataType = "float") {
                NumPut("Float", Float(val), dataBuf)
                dataSize := 4
            } else {
                strVal := String(val)
                encoded := Buffer(StrPut(strVal, "UTF-8"))
                StrPut(strVal, encoded, "UTF-8")
                dataSize := StrLen(strVal)
                dataBuf := encoded
            }
            result := this.NtWriteMem(address, dataBuf, dataSize)
            if (result && dataSize >= 4)
                this.NtFlushCache(address, dataSize)
            return result
        } catch {
            return false
        }
    }

    static BatchWrite(flagsMap) {
        if (!this.hProcess)
            return {success: 0, fail: 0}
        success := 0
        fail := 0

        this.SuspendProcess()
        Sleep(5)

        for key, flagData in flagsMap {
            if (GlobalOffsets.Has(key)) {
                addr := this.baseAddr + GlobalOffsets[key]
                if (addr != this.baseAddr) {
                    if this.WriteMemory(addr, flagData.value, flagData.type)
                        success++
                    else
                        fail++
                } else {
                    fail++
                }
            } else {
                fail++
            }
            Sleep(2)
        }

        Sleep(5)
        this.ResumeProcess()

        return {success: success, fail: fail}
    }

    static DetectType(val) {
        vLow := StrLower(val)
        if (vLow = "true" || vLow = "false")
            return "bool"
        else if IsNumber(val)
            return InStr(val, ".") ? "float" : "int"
        return "string"
    }
}

class FFlagLimiter {
    static Limits := Map(
        "DFIntCullFactorPixelThresholdShadowMapLowQuality", {min: 0, max: 100000},
        "DFIntCullFactorPixelThresholdShadowMapHighQuality", {min: 0, max: 100000},
        "FIntSmoothTerrainPhysicsCacheSize", {min: 0, max: 1000000},
        "DFIntNumAssetsMaxToPreload", {min: 0, max: 100000},
        "DFIntTeleportClientAssetPreloadingHundredthsPercentage", {min: 0, max: 100000},
        "DFIntTeleportClientAssetPreloadingHundredthsPercentage2", {min: 0, max: 100000},
        "FIntRuntimeMaxNumOfThreads", {min: 1, max: 2400},
        "DFIntTaskSchedulerTargetFps", {min: 30, max: 1000},
        "FIntTargetRefreshRate", {min: 60, max: 500},
        "FIntCameraMaxZoomDistance", {min: 1, max: 100000},
        "FIntCSGLevelOfDetailSwitchingDistance", {min: 0, max: 10000},
        "FIntFRMMinGrassDistance", {min: 0, max: 500},
        "FIntFRMMaxGrassDistance", {min: 0, max: 500},
        "FIntRenderLocalLightUpdatesMin", {min: 0, max: 1000},
        "FIntRenderLocalLightUpdatesMax", {min: 0, max: 1000},
        "FIntRenderLocalLightFadeInMs", {min: 0, max: 10000},
        "DFIntHttpParallelLimit_RequestExperienceNotificationService", {min: 0, max: 100},
        "FIntConnectionMTUSize", {min: 500, max: 9000},
        "DFIntRakNetMtuValue1InBytes", {min: 500, max: 9000},
        "FIntBloomFrmCutoff", {min: -100, max: 100},
        "FIntRobloxGuiBlurIntensity", {min: 0, max: 100},
        "DFIntTextureQualityOverride", {min: 0, max: 10},
        "FIntFontSizePadding", {min: 0, max: 50},
        "FIntRenderShadowIntensity", {min: 0, max: 100},
        "FIntDebugForceMSAASamples", {min: 0, max: 8},
        "DFIntDebugFRMQualityLevelOverride", {min: 0, max: 20},
        "FIntDebugFRMOptionalMSAALevelOverride", {min: 0, max: 8},
        "FIntRomarkStartWithGraphicQualityLevel", {min: 0, max: 10},
        "FIntGrassMovementReducedMotionFactor", {min: 0, max: 100},
        "FIntDirectionalAttenuationMaxPoints", {min: 1, max: 1000},
        "FIntRenderMaxShadowAtlasUsageBeforeDownscale", {min: 1, max: 100},
        "DFIntRakNetLoopMs", {min: 0, max: 1000},
        "DFIntDefaultTimeoutTimeMs", {min: 1000, max: 60000},
        "FIntBootstrapperWebView2InstallationTelemetryHundredthPercent", {min: 0, max: 100},
        "FIntEnableVisBugChecksHundredthPercent27", {min: 0, max: 100},
        "FIntCAP1209DataSharingRolloutPercentage", {min: 0, max: 100},
        "FIntPreferredTextSizeSettingBetaFeatureRolloutPercent", {min: 0, max: 100},
        "FIntFriendRequestNotificationThrottle", {min: 0, max: 10000},
        "FIntStudioExternalNotificationImplMessageWriteTimeOut", {min: 0, max: 60000},
        "FIntVertexSmoothingGroupTolerance", {min: 0, max: 100},
        "FIntOcclusionCullingBetaFeatureRolloutPercent", {min: 0, max: 100},
        "FIntEnableCullableScene2HundredthPercent3", {min: 0, max: 100},
        "DFIntPerformanceControlTextureQualityBestUtility", {min: -10, max: 100},
        "DFIntGraphicsOptimizationModeMaxFrameTimeTargetMs", {min: 5, max: 200},
        "DFIntGraphicsOptimizationModeMinFrameTimeTargetMs", {min: 5, max: 200},
        "FIntRenderGrassDetailStrands", {min: 0, max: 100},
        "FIntSSAOMipLevels", {min: 0, max: 10},
        "FIntTextureCompositorLowResFactor", {min: 0, max: 16},
        "DFIntAnimationLodFacsVisibilityDenominator", {min: 0, max: 1000},
        "DFIntAnimationLodFacsDistanceMax", {min: 0, max: 10000},
        "DFIntAnimationLodFacsDistanceMin", {min: 0, max: 10000},
        "FIntSelfViewTooltipLifetime", {min: 0, max: 60},
        "FIntNewInGameMenuPercentRollout3", {min: 0, max: 100},
        "FIntFullscreenTitleBarTriggerDelayMillis", {min: 0, max: 3600000},
        "FIntTerrainArraySliceSize", {min: 0, max: 10000},
        "FIntDebugTextureManagerSkipMips", {min: 0, max: 10},
        "FIntFixForBulkPresenceNotifications", {min: 0, max: 100},
        "FIntCAP1209DataSharingTOSVersion", {min: 0, max: 10},
        "DFIntRaknetBandwidthInfluxHundredthsPercentageV2", {min: 0, max: 100000},
        "DFIntMacWebViewTelemetryThrottleHundredthsPercent", {min: 0, max: 100},
        "DFIntHACDPointSampleDistApartTenths", {min: 0, max: 100000},
        "DFIntReportServerConnectionLostHundredthsPercent", {min: 0, max: 100},
        "DFIntContentProviderPreloadHangTelemetryHundredthsPercentage", {min: 0, max: 100},
        "DFIntWaitOnRecvFromLoopEndedMS", {min: 0, max: 10000},
        "DFIntDebugRestrictGCDistance", {min: 0, max: 10000},
        "DFIntDebugAdditionalNumberOfMipsToSkipForNonAlbedoTextures", {min: 0, max: 100},
        "DFIntDebugLimitMinTextureResolutionWhenSkipMips", {min: 0, max: 1000},
        "DFIntMicroProfilerDpiScaleOverride", {min: 0, max: 1000},
        "FIntUITextureMaxUpdateDepth", {min: -1, max: 100},
        "FIntAXAdaptiveScrollingJustSelectedMillis", {min: 0, max: 10000},
        "FIntStudioResendDisconnectNotificationInterval", {min: 0, max: 60000},
        "FIntLodMinSize", {min: 0, max: 1000},
        "FIntRenderMeshContentMinLod", {min: 0, max: 10}
    )

    static ClampValue(flagName, value, flagType) {
        if (flagType = "bool" || flagType = "string")
            return value
        if (flagType = "float") {
            try {
                fval := Float(value)
                if (fval > 1000000)
                    return "1000000.0"
                if (fval < -1000000)
                    return "-1000000.0"
            }
            return value
        }
        if (flagType = "int") {
            try {
                ival := Integer(value)
                if (this.Limits.Has(flagName)) {
                    lim := this.Limits[flagName]
                    ival := Max(lim["min"], Min(lim["max"], ival))
                    return String(ival)
                }
                if (ival > MaxIntValue)
                    return String(MaxIntValue)
                if (ival < MinIntValue)
                    return String(MinIntValue)
            }
            return value
        }
        return value
    }

    static ValidateFlag(flagName, value, &outType) {
        vLow := StrLower(value)
        if (vLow = "true" || vLow = "false") {
            outType := "bool"
            return value
        }
        if IsNumber(value) {
            if InStr(value, ".") {
                outType := "float"
                return this.ClampValue(flagName, value, "float")
            }
            outType := "int"
            return this.ClampValue(flagName, value, "int")
        }
        outType := "string"
        return this.ClampValue(flagName, value, "string")
    }
}

LeitostrapGui := Gui("-Caption +Border")
LeitostrapGui.BackColor := "0x111111"

WB := LeitostrapGui.Add("ActiveX", "x0 y0 w900 h650 vWB", "Shell.Explorer").Value

class WBEvents {
    TitleChange(Text, *) {
        static lastText := ""
        static lastTick := 0
        if (Text = lastText && A_TickCount - lastTick < 300)
            return
        if InStr(Text, "||") {
            lastText := Text
            lastTick := A_TickCount
            parts := StrSplit(Text, "||")
            cmd := parts[1]
            data := parts.Length > 1 ? parts[2] : ""
            SetTimer(() => ProcessCommand(cmd, data), -1)
        }
    }
}

ComObjConnect(WB, WBEvents())

HTML_CONTENT := '
(
<!DOCTYPE html>
<html>
<head>
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#111;color:#eee;font-family:"Segoe UI",sans-serif;overflow:hidden;user-select:none;display:flex;height:100vh}

::-webkit-scrollbar{width:8px}
::-webkit-scrollbar-track{background:#1a1a1a}
::-webkit-scrollbar-thumb{background:#444;border-radius:4px}
::-webkit-scrollbar-thumb:hover{background:#666}

.sidebar{width:60px;background:#0d0d0d;border-right:1px solid #222;display:flex;flex-direction:column;align-items:center;padding:16px 0;flex-shrink:0}
.sbtn{width:38px;height:38px;border-radius:8px;border:none;background:transparent;color:#666;cursor:pointer;display:flex;align-items:center;justify-content:center;position:relative;margin-bottom:12px}
.sbtn:hover{background:#1a1a1a;color:#ccc}
.sbtn.on{background:#1a1a1a;color:#fff}
.sbtn.on::before{content:"";position:absolute;left:0;top:8px;bottom:8px;width:3px;background:#fff;border-radius:0 3px 3px 0}
.sbtn svg{width:18px;height:18px;pointer-events:none}
.sspacer{flex:1}
.sbtn-x{color:#888}
.sbtn-x:hover{background:#2a1014;color:#ff4444}

.wrap{display:flex;flex-direction:column;flex:1;overflow:hidden}
.tbar{height:38px;background:#0d0d0d;display:flex;align-items:center;justify-content:space-between;padding:0 20px;border-bottom:1px solid #222;flex-shrink:0}
.tbar-title{font-size:13px;font-weight:700;color:#fff;letter-spacing:1px}
.tbar-ver{font-size:9px;color:#444;font-weight:400;margin-left:6px;letter-spacing:0.5px}
.tbar-status{font-size:10px;color:#555}

.content{flex:1;overflow-y:auto;padding:24px 28px}
.sec{display:none}
.sec.on{display:block}

.stitle{font-size:17px;font-weight:700;color:#fff;margin-bottom:6px}
.sdesc{font-size:12px;color:#555;margin-bottom:22px;line-height:1.5}

.card{background:#161616;border:1px solid #282828;border-radius:8px;padding:18px;margin-bottom:16px}
.card-h{font-size:13px;font-weight:600;color:#ccc;margin-bottom:12px}
.card-r{display:flex;align-items:center;margin-bottom:10px}
.card-r label{font-size:11px;color:#666;width:140px;flex-shrink:0}
.card-r .v{font-size:11px;color:#ddd;font-family:Consolas,monospace}

.etoolbar{display:flex;gap:14px;margin-bottom:16px;flex-wrap:wrap}
.ewrap{display:flex;flex-direction:column;height:calc(100vh - 190px)}
textarea{flex:1;background:#0d0d0d;border:1px solid #282828;color:#ddd;padding:14px;font-family:"Cascadia Code",Consolas,monospace;font-size:12px;resize:none;border-radius:6px;outline:none;line-height:1.6}
textarea:focus{border-color:#555}

.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;background:#1a1a1a;border:1px solid #333;color:#ddd;padding:10px 20px;border-radius:6px;cursor:pointer;font-weight:500;font-size:11px;white-space:nowrap;transition:0.15s;margin:0 4px}
.btn:hover{background:#252525;border-color:#555}
.btn-w{background:#fff;color:#000;border-color:#fff}.btn-w:hover{background:#ddd}
.btn-d{background:#1a1010;color:#ff4444;border-color:#332020}.btn-d:hover{background:#2a1515}
.btn svg{width:13px;height:13px;pointer-events:none}

.sgrid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:18px}
.scard{background:#161616;border:1px solid #282828;border-radius:8px;padding:14px;text-align:center}
.sval{font-size:22px;font-weight:700;color:#fff;font-family:Consolas,monospace}
.slbl{font-size:9px;color:#555;margin-top:6px;text-transform:uppercase;letter-spacing:0.5px}

.dgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:8px;max-height:calc(100vh - 300px);overflow-y:auto;padding-right:6px}
.ditem{background:#0d0d0d;border:1px solid #282828;border-radius:6px;padding:9px 12px;cursor:pointer;display:flex;align-items:center;gap:10px;transition:0.12s}
.ditem:hover{border-color:#555;background:#1a1a1a}
.dname{font-size:10px;color:#ccc;font-family:Consolas,monospace;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.dbadge{font-size:8px;padding:2px 8px;border-radius:3px;font-weight:600;flex-shrink:0}
.bi{background:#1a2030;color:#6ea8ff}
.bb{background:#251a30;color:#b48eff}
.bs{background:#1a3020;color:#5abf6a}

.dsearch{display:flex;gap:10px;margin-bottom:14px}
.dsearch input{flex:1;background:#0d0d0d;border:1px solid #282828;color:#ddd;padding:10px 14px;border-radius:6px;font-size:12px;outline:none}
.dsearch input:focus{border-color:#555}
.dstats{display:flex;gap:20px;margin-bottom:14px;font-size:11px;color:#555}
.dstats span{display:flex;align-items:center;gap:6px}
.dot{width:8px;height:8px;border-radius:50%;display:inline-block}

.sbar{height:28px;background:#0d0d0d;border-top:1px solid #222;display:flex;align-items:center;justify-content:space-between;padding:0 14px;font-size:10px;flex-shrink:0}
.sbar-l{display:flex;align-items:center;gap:10px}
.sdot{width:8px;height:8px;border-radius:50%;background:#ff4444}
.sdot.ok{background:#44cc44}
.stxt{color:#555}
.sbar-r{color:#444}

.toast{position:fixed;bottom:40px;right:24px;font-size:11px;padding:10px 20px;border-radius:6px;background:#fff;color:#000;display:none;font-weight:600;box-shadow:0 8px 32px rgba(0,0,0,0.5);z-index:999}

.tgl-w{display:flex;align-items:center;gap:12px}
.tgl{width:36px;height:20px;background:#282828;border-radius:10px;cursor:pointer;position:relative;border:1px solid #333}
.tgl.on{background:#fff;border-color:#fff}
.tgl::after{content:"";position:absolute;top:2px;left:2px;width:14px;height:14px;border-radius:50%;background:#666}
.tgl.on::after{left:18px;background:#000}
.tgl-l{font-size:11px;color:#666}

.log{background:#0d0d0d;border:1px solid #282828;border-radius:6px;padding:10px;font-family:Consolas,monospace;font-size:10px;max-height:200px;overflow-y:auto;line-height:1.7}
.le{color:#555}.lok{color:#44cc44}.lfail{color:#ff4444}.linfo{color:#aaa}
</style>
</head>
<body>
<div class="sidebar">
    <button class="sbtn on" id="sb_editor" onclick="goTo(0)" title="Editor"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="m16.862 4.487 1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L10.582 16.07a4.5 4.5 0 0 1-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 0 1 1.13-1.897l8.932-8.931Zm0 0L19.5 7.125M18 14v4.75A2.25 2.25 0 0 1 15.75 21H5.25A2.25 2.25 0 0 1 3 18.75V8.25A2.25 2.25 0 0 1 5.25 6H10"/></svg></button>
    <button class="sbtn" id="sb_database" onclick="goTo(1)" title="Database"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M20.25 6.375c0 2.278-3.694 4.125-8.25 4.125S3.75 8.653 3.75 6.375m16.5 0c0-2.278-3.694-4.125-8.25-4.125S3.75 4.097 3.75 6.375m16.5 0v11.25c0 2.278-3.694 4.125-8.25 4.125s-8.25-1.847-8.25-4.125V6.375m16.5 0v3.75m-16.5-3.75v3.75m16.5 0v3.75C20.25 16.153 16.556 18 12 18s-8.25-1.847-8.25-4.125v-3.75m16.5 0c0 2.278-3.694 4.125-8.25 4.125s-8.25-1.847-8.25-4.125"/></svg></button>
    <button class="sbtn" id="sb_injection" onclick="goTo(2)" title="Injection"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M6 12 3.269 3.125A59.769 59.769 0 0 1 21.485 12 59.768 59.768 0 0 1 3.27 20.875L5.999 12Zm0 0h7.5"/></svg></button>
    <button class="sbtn" id="sb_settings" onclick="goTo(3)" title="Settings"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 0 1 1.37.49l1.296 2.247a1.125 1.125 0 0 1-.26 1.431l-1.003.827c-.293.241-.438.613-.43.992a7.723 7.723 0 0 1 0 .255c-.008.378.137.75.43.991l1.004.827c.424.35.534.955.26 1.43l-1.298 2.247a1.125 1.125 0 0 1-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 0 1-.22.128c-.331.183-.581.495-.644.869l-.213 1.281c-.09.543-.56.94-1.11.94h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 0 1-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 0 1-1.369-.49l-1.297-2.247a1.125 1.125 0 0 1 .26-1.431l1.004-.827c.292-.24.437-.613.43-.991a6.932 6.932 0 0 1 0-.255c.007-.38-.138-.751-.43-.992l-1.004-.827a1.125 1.125 0 0 1-.26-1.43l1.297-2.247a1.125 1.125 0 0 1 1.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.086.22-.128.332-.183.582-.495.644-.869l.214-1.28Z"/><path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"/></svg></button>
    <div class="sspacer"></div>
    <button class="sbtn" onclick="sendCommand('min')" title="Minimize"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M19.5 12h-15"/></svg></button>
    <button class="sbtn sbtn-x" onclick="sendCommand('close')" title="Close"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M6 18 18 6M6 6l12 12"/></svg></button>
</div>

<div class="wrap">
    <div class="tbar" id="dragzone">
        <span class="tbar-title">LEITOSTRAP<span class="tbar-ver">v2.0 ahk</span></span>
        <span class="tbar-status" id="rob_status">Waiting for Roblox...</span>
    </div>

    <div class="content">
        <div class="sec on" id="sec-0">
            <div class="stitle">FFlag Editor</div>
            <div class="sdesc">Write or paste your FFlag JSON configuration below, then inject.</div>
            <div class="ewrap">
                <div class="etoolbar">
                    <button class="btn btn-w" onclick="sendCommand('apply')"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M6 12 3.269 3.125A59.769 59.769 0 0 1 21.485 12 59.768 59.768 0 0 1 3.27 20.875L5.999 12Zm0 0h7.5"/></svg> Apply</button>
                    <button class="btn" onclick="sendCommand('import')"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M3 16.5v2.25A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75V16.5M16.5 12 12 16.5m0 0L7.5 12m4.5 4.5V3"/></svg> Import</button>
                    <button class="btn" onclick="sendCommand('export')"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M3 16.5v2.25A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75V16.5m-13.5-9L12 3m0 0 4.5 4.5M12 3v13.5"/></svg> Export</button>
                    <button class="btn btn-d" onclick="sendCommand('clear')"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="m14.74 9-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 0 1-2.244 2.077H8.084a2.25 2.25 0 0 1-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 0 0-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 0 1 3.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 0 0-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 0 0-7.5 0"/></svg> Clear</button>
                </div>
                <textarea id="jsonEditor" spellcheck="false" placeholder="{ }">{}</textarea>
            </div>
        </div>

        <div class="sec" id="sec-1">
            <div class="stitle">Offset Database</div>
            <div class="sdesc">All loaded FFlag offsets. Click any flag to add it to the editor.</div>
            <div class="dstats">
                <span><span class="dot" style="background:#6ea8ff"></span> <span id="dbTotal">0</span> Total</span>
                <span><span class="dot" style="background:#5abf6a"></span> <span id="dbInt">0</span> Int</span>
                <span><span class="dot" style="background:#b48eff"></span> <span id="dbBool">0</span> Bool</span>
                <span><span class="dot" style="background:#ff9944"></span> <span id="dbStr">0</span> String</span>
            </div>
            <div class="dsearch">
                <input type="text" id="dbSearchInput" placeholder="Search FFlags..." oninput="filterDB()">
                <button class="btn btn-w" onclick="addAllFiltered()">Add All Filtered</button>
            </div>
            <div class="dgrid" id="dbGrid"></div>
        </div>

        <div class="sec" id="sec-2">
            <div class="stitle">Injection Monitor</div>
            <div class="sdesc">Track injection status, reapplied flags, and view the live log.</div>
            <div class="sgrid">
                <div class="scard"><div class="sval" id="statApplied">0</div><div class="slbl">Applied</div></div>
                <div class="scard"><div class="sval" id="statFailed">0</div><div class="slbl">Failed</div></div>
                <div class="scard"><div class="sval" id="statReapplied">0</div><div class="slbl">Reapplied</div></div>
                <div class="scard"><div class="sval" id="statActive">0</div><div class="slbl">Active Flags</div></div>
            </div>
            <div class="card">
                <div class="card-h">Injection Details</div>
                <div class="card-r"><label>Method</label><div class="v">NtWriteVirtualMemory (Direct)</div></div>
                <div class="card-r"><label>Process Control</label><div class="v">NtSuspendProcess / NtResumeProcess</div></div>
                <div class="card-r"><label>Reapply</label><div class="v" id="persistStatus">Disabled</div></div>
                <div class="card-r"><label>Value Limiter</label><div class="v">Enabled - Clamps dangerous values</div></div>
                <div class="card-r"><label>Last Inject</label><div class="v" id="lastInjectTime">Never</div></div>
            </div>
            <div class="card">
                <div class="card-h">Log</div>
                <div class="log" id="logArea">
                    <div class="le linfo">[SYSTEM] Leitostrap initialized</div>
                </div>
            </div>
        </div>

        <div class="sec" id="sec-3">
            <div class="stitle">Settings</div>
            <div class="sdesc">Configure injection behavior and preferences.</div>
            <div class="card">
                <div class="card-h">Injection</div>
                <div class="card-r">
                    <label>Reapply</label>
                    <div class="tgl-w">
                        <div class="tgl" id="toggleReapply" onclick="toggleReapply()"></div>
                        <span class="tgl-l">Re-apply flags every</span>
                        <input type="number" id="reapplyMs" value="1000" min="500" max="3000" step="100" style="width:70px;background:#0d0d0d;border:1px solid #282828;color:#ddd;padding:6px 10px;border-radius:5px;font-size:12px;text-align:center;outline:none" onchange="sendCommand('set_reapply_ms',this.value)">
                        <span class="tgl-l">ms</span>
                    </div>
                </div>
                <div class="card-r">
                    <label>Value Limiter</label>
                    <div class="tgl-w">
                        <div class="tgl on" id="toggleLimiter"></div>
                        <span class="tgl-l">Clamp dangerous int values</span>
                    </div>
                </div>
            </div>
            <div class="card">
                <div class="card-h">About</div>
                <div class="card-r"><label>Version</label><div class="v">Leitostrap AHK v2.0</div></div>
                <div class="card-r"><label>Engine</label><div class="v">NtWriteVirtualMemory + NtSuspendProcess</div></div>
                <div class="card-r"><label>Offsets</label><div class="v" id="offsetCount">Loading...</div></div>
                <div class="card-r"><label>Status</label><div class="v" id="overallStatus">Initializing</div></div>
            </div>
        </div>
    </div>

    <div class="sbar">
        <div class="sbar-l">
            <div class="sdot" id="statusDot"></div>
            <span class="stxt" id="statusText">Disconnected</span>
        </div>
        <div class="sbar-r"><span id="flagCount">0 flags loaded</span></div>
    </div>
</div>

<div class="toast" id="toast"></div>

<script>
var _d=[],_cur=0;
var _secs=["sec-0","sec-1","sec-2","sec-3"];
var _sbs=["sb_editor","sb_database","sb_injection","sb_settings"];

function sendCommand(c,d){document.title=c+"||"+(d?d:"")}

function goTo(n){
    _cur=n;
    for(var i=0;i<4;i++){
        var s=document.getElementById(_secs[i]);
        if(s){s.className=(i===n)?"sec on":"sec"}
        var b=document.getElementById(_sbs[i]);
        if(b){b.className=(i===n)?"sbtn on":"sbtn"}
    }
}

function showToast(m,c){
    var t=document.getElementById("toast");
    t.innerText=m;
    t.style.background=c||"#fff";
    t.style.color=c?"#fff":"#000";
    t.style.display="block";
    setTimeout(function(){t.style.display="none"},3000);
}

function addLog(m,t){
    var l=document.getElementById("logArea");
    var e=document.createElement("div");
    e.className="le "+(t||"");
    e.innerText="["+new Date().toLocaleTimeString()+"] "+m;
    l.appendChild(e);
    l.scrollTop=l.scrollHeight;
    if(l.children.length>200)l.removeChild(l.firstChild);
}

function setRobloxStatus(m,c){
    document.getElementById("rob_status").innerText=m;
    document.getElementById("rob_status").style.color=c||"#555";
    var d=document.getElementById("statusDot");
    var s=document.getElementById("statusText");
    if(c==="#44cc44"){d.className="sdot ok";s.innerText="Connected"}
    else{d.className="sdot";s.innerText="Disconnected"}
}

function setStats(a,f,r,ac){
    document.getElementById("statApplied").innerText=a||0;
    document.getElementById("statFailed").innerText=f||0;
    document.getElementById("statReapplied").innerText=r||0;
    document.getElementById("statActive").innerText=ac||0;
}

function setLastInject(t){document.getElementById("lastInjectTime").innerText=t}
function setOffsetCount(c){
    document.getElementById("offsetCount").innerText=c+" offsets loaded";
    document.getElementById("flagCount").innerText=c+" flags loaded";
    document.getElementById("overallStatus").innerText="Ready";
}

function loadDatabase(s){
    _d=s.split(",").filter(function(n){return n.trim()!==""});
    renderDB(_d);
    document.getElementById("dbTotal").innerText=_d.length;
}

function renderDB(arr){
    var g=document.getElementById("dbGrid");
    var h="";
    var mx=arr.length>500?500:arr.length;
    for(var i=0;i<mx;i++){
        if(!arr[i])continue;
        var nm=arr[i];
        var bg="bi",bt="INT";
        var nl=nm.toLowerCase();
        if(nl.indexOf("flag")!==-1||nl.indexOf("enabled")!==-1||nl.indexOf("disabled")!==-1){bg="bb";bt="BOOL"}
        else if(nl.indexOf("string")!==-1||nl.indexOf("url")!==-1||nl.indexOf("address")!==-1){bg="bs";bt="STR"}
        h+='<div class="ditem" onclick="addDbFlag(\''+nm.replace(/'/g,"\\'")+'\')"><span class="dname">'+nm+'</span><span class="dbadge '+bg+'">'+bt+'</span></div>';
    }
    if(arr.length>mx){h+='<div style="text-align:center;color:#555;padding:16px;font-size:11px">... and '+(arr.length-mx)+' more. Type to search.</div>'}
    g.innerHTML=h;
}

function filterDB(){
    var q=document.getElementById("dbSearchInput").value.toLowerCase();
    var f=[];
    for(var i=0;i<_d.length;i++){if(_d[i].toLowerCase().indexOf(q)!==-1)f.push(_d[i])}
    renderDB(f);
}

function addDbFlag(nm){
    try{
        var ed=document.getElementById("jsonEditor");
        var o=JSON.parse(ed.value);
        if(!o)o={};
        if(!o[nm])o[nm]="true";
        ed.value=JSON.stringify(o,null,4);
        showToast("Added: "+nm);
    }catch(e){
        var r=ed.value.replace(/\}\s*$/,"");
        if(r.indexOf("{")===-1)r="{";
        if(r.trim().length>1&&r.trim().slice(-1)!==",")r+=",";
        r+='\n    "'+nm+'": "true"\n}';
        ed.value=r;
        showToast("Added: "+nm);
    }
}

function addAllFiltered(){
    var q=document.getElementById("dbSearchInput").value.toLowerCase();
    var c=0;
    try{
        var ed=document.getElementById("jsonEditor");
        var o=JSON.parse(ed.value||"{}");
        for(var i=0;i<_d.length;i++){
            if(_d[i].toLowerCase().indexOf(q)!==-1){
                if(!o[_d[i]]){o[_d[i]]="true";c++}
            }
        }
        ed.value=JSON.stringify(o,null,4);
        showToast("Added "+c+" flags");
    }catch(e){showToast("Error","#ff4444")}
}

function toggleReapply(){
    var t=document.getElementById("toggleReapply");
    if(t.className==="tgl on"){t.className="tgl";sendCommand("toggle_reapply","0")}
    else{t.className="tgl on";sendCommand("toggle_reapply","1")}
}

function getJson(){return document.getElementById("jsonEditor").value}
function setJson(s){document.getElementById("jsonEditor").value=s}

document.getElementById("dragzone").onmousedown=function(e){
    if(e.target.tagName!=="BUTTON"&&e.target.tagName!=="SVG"&&e.target.tagName!=="PATH"){
        sendCommand("drag");
    }
};
</script>
</body>
</html>
)'

tempHtmlFile := A_Temp "\leitostrap_v2.html"
if FileExist(tempHtmlFile)
    FileDelete(tempHtmlFile)
FileAppend(HTML_CONTENT, tempHtmlFile, "UTF-8")

WB.Navigate("file:///" tempHtmlFile)
while WB.readyState != 4
    Sleep(10)

LeitostrapGui.Show("w900 h650")

RunJS(code) {
    global WB
    try WB.Document.parentWindow.execScript(code)
}

ProcessCommand(cmd, data) {
    if (cmd = "close") {
        ExitApp()
    } else if (cmd = "min") {
        WinMinimize("A")
    } else if (cmd = "drag") {
        DllCall("ReleaseCapture")
        PostMessage(0xA1, 2,,, "ahk_id " LeitostrapGui.Hwnd)
    } else if (cmd = "clear") {
        RunJS("setJson('{}')")
        RunJS("showToast('Editor cleared')")
    } else if (cmd = "import") {
        path := FileSelect(3, , "Select JSON", "JSON Files (*.json)")
        if (path != "") {
            content := FileRead(path)
            escaped := StrReplace(content, "'", "\'")
            escaped := StrReplace(escaped, "`n", "\n")
            escaped := StrReplace(escaped, "`r", "")
            RunJS("setJson('" escaped "')")
            RunJS("showToast('JSON imported')")
            AddLog("Imported JSON from " . path, "info")
        }
    } else if (cmd = "export") {
        path := FileSelect(17, , "Export JSON", "JSON Files (*.json)")
        if (path != "") {
            jsonStr := ""
            try jsonStr := WB.Document.parentWindow.getJson()
            if (jsonStr != "") {
                if FileExist(path)
                    FileDelete(path)
                FileAppend(jsonStr, path, "UTF-8")
                RunJS("showToast('JSON exported')")
                AddLog("Exported JSON to " . path, "info")
            }
        }
    } else if (cmd = "apply" || cmd = "inject") {
        ApplyConfig()
    } else if (cmd = "toggle_reapply") {
        PersistentMode := (data = "1")
        if (PersistentMode) {
            RunJS("showToast('Reapply enabled')")
            RunJS("document.getElementById('persistStatus').innerText='Every " . ReapplyInterval . "ms'")
            AddLog("Reapply enabled", "ok")
        } else {
            RunJS("showToast('Reapply disabled')")
            RunJS("document.getElementById('persistStatus').innerText='Disabled'")
            AddLog("Reapply disabled", "info")
            if (ReapplyTimerActive) {
                ReapplyTimerActive := false
                SetTimer(ReapplyMonitor, 0)
            }
        }
    } else if (cmd = "set_reapply_ms") {
        ReapplyInterval := Max(500, Min(3000, Integer(data)))
        RunJS("showToast('Reapply interval: " . ReapplyInterval . "ms')")
        if (PersistentMode)
            RunJS("document.getElementById('persistStatus').innerText='Every " . ReapplyInterval . "ms'")
        AddLog("Reapply interval set to " . ReapplyInterval . "ms", "info")
        if (ReapplyTimerActive) {
            SetTimer(ReapplyMonitor, 0)
            SetTimer(ReapplyMonitor, ReapplyInterval)
        }
    }
}

AddLog(msg, type := "") {
    escaped := StrReplace(msg, "'", "\'")
    escaped := StrReplace(escaped, "`n", " ")
    RunJS("addLog('" escaped "', '" type "')")
}

ApplyConfig() {
    global RobloxID, GlobalOffsets, InjectedFlagsMap, PersistentMode, ReapplyTimerActive, ReapplyInterval

    if (!RobloxID) {
        RunJS("showToast('Roblox not detected')")
        AddLog("Roblox not detected - cannot inject", "fail")
        return
    }

    jsonStr := ""
    try {
        jsonStr := WB.Document.parentWindow.getJson()
    } catch {
        RunJS("showToast('Error reading JSON')")
        return
    }

    flagsToInject := Map()
    pos := 1
    while (pos := RegExMatch(jsonStr, '"(?P<K>[^"]+)":\s*(?:"(?P<V>[^"]*)"|(?P<VN>[^,\}\s]+))', &m, pos)) {
        key := m["K"]
        val := (m["V"] != "") ? m["V"] : m["VN"]
        cleanKey := RegExReplace(key, "^(DFString|SFString|FString|DFFlag|SFFlag|DFInt|DFLog|FFlag|FInt|FLog|SFInt|Int)")

        validatedVal := FFlagLimiter.ValidateFlag(cleanKey, val, &detectedType)
        flagsToInject[cleanKey] := {value: validatedVal, type: detectedType, originalKey: key}
        pos += m.Len
    }

    if (flagsToInject.Count = 0) {
        RunJS("showToast('No flags to apply')")
        return
    }

    if (flagsToInject.Count > 200) {
        AddLog("Warning: Injecting " . flagsToInject.Count . " flags - values have been clamped for safety", "info")
    }

    startTime := A_TickCount
    InjectedFlagsMap := Map()

    Core.SuspendProcess()
    Sleep(5)

    successCount := 0
    failCount := 0

    for key, flagData in flagsToInject {
        if (!GlobalOffsets.Has(key)) {
            failCount++
            continue
        }
        addr := Core.baseAddr + GlobalOffsets[key]
        if (addr = Core.baseAddr) {
            failCount++
            continue
        }
        if Core.WriteMemory(addr, flagData.value, flagData.type) {
            successCount++
            InjectedFlagsMap[key] := flagData
        } else {
            failCount++
        }
        Sleep(2)
    }

    Sleep(5)
    Core.ResumeProcess()

    elapsed := A_TickCount - startTime
    RunJS("showToast('Applied: " successCount " | Failed: " failCount " | " . elapsed . "ms')")
    RunJS("setStats(" successCount ", " failCount ", 0, " InjectedFlagsMap.Count ")")
    RunJS("setLastInject('" . FormatTime(, "HH:mm:ss") . "')")

    AddLog("Injection complete: " . successCount . " ok, " . failCount . " fail (" . elapsed . "ms)", "ok")

    if (PersistentMode && !ReapplyTimerActive) {
        ReapplyTimerActive := true
        SetTimer(ReapplyMonitor, ReapplyInterval)
        AddLog("Reapply monitor started (" . ReapplyInterval . "ms interval)", "info")
    }
}

ReapplyMonitor() {
    global InjectedFlagsMap, RobloxID, ReapplyTimerActive, PersistentMode, ReapplyInterval

    if (!PersistentMode || InjectedFlagsMap.Count = 0 || !RobloxID) {
        ReapplyTimerActive := false
        SetTimer(ReapplyMonitor, 0)
        return
    }

    pid := ProcessExist("RobloxPlayerBeta.exe")
    if (!pid) {
        RobloxID := 0
        RunJS("setRobloxStatus('Waiting for Roblox...', '#555')")
        ReapplyTimerActive := false
        SetTimer(ReapplyMonitor, 0)
        return
    }

    if (pid != RobloxID) {
        RobloxID := pid
        if (Core.Init(pid)) {
            RunJS("setRobloxStatus('Roblox Attached (PID " pid ")', '#44cc44')")
        }
    }

    if (!Core.hProcess)
        return

    Core.SuspendProcess()
    Sleep(3)

    reappliedCount := 0
    for key, flagData in InjectedFlagsMap {
        if (GlobalOffsets.Has(key)) {
            addr := Core.baseAddr + GlobalOffsets[key]
            if (addr != Core.baseAddr) {
                Core.WriteMemory(addr, flagData.value, flagData.type)
                reappliedCount++
            }
            Sleep(2)
        }
    }

    Sleep(3)
    Core.ResumeProcess()

    if (reappliedCount > 0) {
        static totalReapplied := 0
        totalReapplied += reappliedCount
        RunJS("setStats(" InjectedFlagsMap.Count ", 0, " totalReapplied ", " InjectedFlagsMap.Count ")")
    }
}

FetchDatabase() {
    global GlobalOffsets
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("GET", "https://imtheo.lol/Offsets/FFlags.hpp", true)
        req.Send()
        req.WaitForResponse()

        pos := 1
        strArr := ""
        if RegExMatch(req.ResponseText, "s)namespace FFlags\s*\{([^}]+)\}", &contentMatch) {
            block := contentMatch[1]
            while (pos := RegExMatch(block, "uintptr_t\s+(\w+)\s*=\s*(0x[0-9A-Fa-f]+);", &m, pos)) {
                GlobalOffsets[m[1]] := Integer(m[2])
                strArr .= m[1] ","
                pos += m.Len
            }
        }
        strArr := RTrim(strArr, ",")
        RunJS("loadDatabase('" strArr "')")
        RunJS("setOffsetCount(" GlobalOffsets.Count ")")
        AddLog("Database loaded: " . GlobalOffsets.Count . " offsets", "ok")
    } catch {
        RunJS("showToast('Failed to load database')")
        AddLog("Failed to load database from server", "fail")
    }
}

MonitorTask() {
    global RobloxID
    pid := ProcessExist("RobloxPlayerBeta.exe")
    if (pid && pid != RobloxID) {
        RobloxID := pid
        if (Core.Init(pid)) {
            RunJS("setRobloxStatus('Roblox Attached (PID " pid ")', '#44cc44')")
            AddLog("Roblox attached (PID " pid ")", "ok")
        }
    } else if (!pid && RobloxID) {
        RobloxID := 0
        RunJS("setRobloxStatus('Waiting for Roblox...', '#555')")
    }
}

SetTimer(MonitorTask, 500)
SetTimer(FetchDatabase, -100)

AddLog("Leitostrap v2.0", "info")