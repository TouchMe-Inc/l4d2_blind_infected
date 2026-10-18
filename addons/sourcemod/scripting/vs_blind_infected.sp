#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <left4dhooks>


public Plugin myinfo = {
    name        = "VersusBlindInfected",
    author      = "CanadaRox, ProdigySim, TouchMe, Ferks-FK",
    description = "Hides all items from the infected team until they are (possibly) visible to one of the survivors to prevent exploration of the map",
    version     = "build_0004",
    url         = "https://github.com/TouchMe-Inc/l4d2_blind_infected"
};


#define TEAM_SURVIVOR           2
#define TEAM_INFECTED           3

#define ENT_CHECK_SLICE         0.1
#define ENT_CHECK_SLICES        10

#define TRACE_TOLERANCE         75.0
#define ENTITY_NAME_SIZE        32

#define MAX_ENTS                2048


ArrayList g_hHiddenEntityRefs = null;

int g_iCursor = 0;

bool g_bHiddenEntityIndex[MAX_ENTS + 1];

ConVar g_cvSurvivorLimit = null;
int    g_iSurvivorLimit = 0;


bool g_bLateLoad = false;

/**
 * Called before OnPluginStart.
 *
 * @param myself      Handle to the plugin
 * @param bLate       Whether or not the plugin was loaded "late" (after map load)
 * @param sErr        Error message buffer in case load failed
 * @param iErrLen     Maximum number of characters for error message buffer
 * @return            APLRes_Success | APLRes_SilentFailure
 */
public APLRes AskPluginLoad2(Handle myself, bool bLate, char[] sErr, int iErrLen)
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(sErr, iErrLen, "Plugin only supports Left 4 Dead 2");
        return APLRes_SilentFailure;
    }

    g_bLateLoad = bLate;

    return APLRes_Success;
}

public void OnPluginStart()
{
    g_hHiddenEntityRefs = CreateArray();

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

    g_cvSurvivorLimit = FindConVar("survivor_limit");
    g_iSurvivorLimit = GetConVarInt(g_cvSurvivorLimit);
    HookConVarChange(g_cvSurvivorLimit, OnSurvivorLimitChanged);

    CreateTimer(ENT_CHECK_SLICE, Timer_EntCheck, .flags = TIMER_REPEAT);

    if (g_bLateLoad)
    {
        for (int iClient = 1; iClient <= MaxClients; iClient++)
        {
            if (IsClientInGame(iClient)) {
                OnClientPutInServer(iClient);
            }
        }
    }
}

public void OnSurvivorLimitChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    g_iSurvivorLimit = GetConVarInt(convar);
}

void Event_RoundStart(Event event, const char[] sEventName, bool bDontBroadcast)
{
    ResetHiddenEntities();

    ArrayList hPlayerItems = CreateArray();

    int iWeapon = -1;

    for (int iClient = 1; iClient <= MaxClients; iClient++)
    {
        if (!IsClientInGame(iClient) || !IsClientSurvivor(iClient)) {
            continue;
        }

        if ((iWeapon = GetPlayerWeaponSlot(iClient, 0)) != -1) {
            PushArrayCell(hPlayerItems, iWeapon);
        }

        if ((iWeapon = GetPlayerWeaponSlot(iClient, 1)) != -1) {
            PushArrayCell(hPlayerItems, iWeapon);
        }
    }

    char szEntClassname[ENTITY_NAME_SIZE];
    int iEntityCount = GetMaxEntities();

    for (int iEnt = (MaxClients + 1); iEnt < iEntityCount; iEnt ++)
    {
        if (!IsValidEntity(iEnt) || !IsValidEdict(iEnt)) {
            continue;
        }

        if (FindValueInArray(hPlayerItems, iEnt) != -1) {
            continue;
        }

        GetEdictClassname(iEnt, szEntClassname, sizeof szEntClassname);
        if (szEntClassname[0] != 'w' || szEntClassname[6] != '_' || StrContains(szEntClassname, "_claw", true) != -1) {
            continue;
        }

        PushArrayCell(g_hHiddenEntityRefs, EntIndexToEntRef(iEnt));

        g_bHiddenEntityIndex[iEnt] = true;

        SDKHook(iEnt, SDKHook_SetTransmit, Hook_SetTransmit);
    }

    CloseHandle(hPlayerItems);
}

public void OnClientPutInServer(int iClient) {
    SDKHook(iClient, SDKHook_WeaponEquipPost, OnWeaponEquipPost);
}

void OnWeaponEquipPost(int iClient, int iWeapon)
{
    if (IsNotClientIndex(iWeapon) && g_bHiddenEntityIndex[iWeapon]) {
        ShowEntity(iWeapon);
    }
}

public void OnEntityDestroyed(int iEntity)
{
    if (IsNotClientIndex(iEntity)) {
        g_bHiddenEntityIndex[iEntity] = false;
    }
}

Action Timer_EntCheck(Handle hTimer)
{
    int iSize = GetArraySize(g_hHiddenEntityRefs);
    if (iSize == 0) {
        return Plugin_Continue;
    }

    if (g_iCursor >= iSize) {
        g_iCursor = 0;
    }

    int iProcessed = 0;
    int iBatch = (iSize + ENT_CHECK_SLICES - 1) / ENT_CHECK_SLICES;

    while (iProcessed < iBatch && g_iCursor < GetArraySize(g_hHiddenEntityRefs))
    {
        int iEntityRef = GetArrayCell(g_hHiddenEntityRefs, g_iCursor);
        int iEntity = EntRefToEntIndex(iEntityRef);

        if (iEntity == INVALID_ENT_REFERENCE || !g_bHiddenEntityIndex[iEntity])
        {
            RemoveFromArray(g_hHiddenEntityRefs, g_iCursor);
            iProcessed++;
            continue;
        }

        if (IsVisibleToSurvivors(iEntity))
        {
            ShowEntity(iEntity);
            RemoveFromArray(g_hHiddenEntityRefs, g_iCursor);
            iProcessed++;
            continue;
        }

        g_iCursor++;
        iProcessed++;
    }

    return Plugin_Continue;
}

bool IsVisibleToSurvivors(int iEntity)
{
    int iSurvivorsCount = 0;

    for (int iClient = 1; iClient <= MaxClients && iSurvivorsCount < g_iSurvivorLimit; iClient ++)
    {
        if (!IsClientInGame(iClient) || !IsClientSurvivor(iClient)) {
            continue;
        }

        iSurvivorsCount++;

        if (IsPlayerAlive(iClient) && IsClientSeeEntity(iClient, iEntity)) {
            return true;
        }
    }

    return false;
}

Action Hook_SetTransmit(int iTransmitEntity, int iClient)
{
    if (!IsNotClientIndex(iTransmitEntity) || !g_bHiddenEntityIndex[iTransmitEntity]) {
        return Plugin_Continue;
    }

    if (IsClientSurvivor(iClient)) {
        return Plugin_Continue;
    }

    return Plugin_Handled;
}

void ShowEntity(int iEntity)
{
    SDKUnhook(iEntity, SDKHook_SetTransmit, Hook_SetTransmit);
    g_bHiddenEntityIndex[iEntity] = false;
}

void ResetHiddenEntities()
{
    for (int iEnt = (MaxClients + 1); iEnt <= MAX_ENTS; iEnt++) {
        g_bHiddenEntityIndex[iEnt] = false;
    }

    if (g_hHiddenEntityRefs != null) {
        ClearArray(g_hHiddenEntityRefs);
    }

    g_iCursor = 0;
}

/**
 * Check an entity for being visible to a client.
 */
bool IsClientSeeEntity(int iClient, int iEntity)
{
    static float vClientOrigin[3], vEntOrigin[3], vLookAt[3], vAngles[3], vEndPosition[3];

    GetClientEyePosition(iClient, vClientOrigin);
    GetEntPropVector(iEntity, Prop_Send, "m_vecOrigin", vEntOrigin);
    MakeVectorFromPoints(vClientOrigin, vEntOrigin, vLookAt);
    GetVectorAngles(vLookAt, vAngles);

    Handle hTrace = TR_TraceRayFilterEx(vClientOrigin, vAngles, MASK_SHOT, RayType_Infinite, Filter_OnlyPhysics);

    bool bIsVisible = true;

    if (TR_DidHit(hTrace))
    {
        TR_GetEndPosition(vEndPosition, hTrace);

        /*
         * if trace ray lenght plus tolerance equal or bigger absolute distance, you hit the targeted zombie.
         */
        bIsVisible = (GetVectorDistance(vClientOrigin, vEndPosition, false) + TRACE_TOLERANCE) >= GetVectorDistance(vClientOrigin, vEntOrigin);
    }

    CloseHandle(hTrace);

    return bIsVisible;
}

bool Filter_OnlyPhysics(int iEnt, int iContentsMask)
{
    if (iEnt <= MaxClients || !IsValidEntity(iEnt)) {
        return false;
    }

    static char szClassname[ENTITY_NAME_SIZE];
    GetEdictClassname(iEnt, szClassname, sizeof(szClassname));

    return (strcmp(szClassname, "prop_physics", false) != 0);
}

bool IsNotClientIndex(int iIndex) {
    return (iIndex > MaxClients && iIndex <= MAX_ENTS);
}

bool IsClientSurvivor(int iClient) {
    return (GetClientTeam(iClient) == TEAM_SURVIVOR);
}
