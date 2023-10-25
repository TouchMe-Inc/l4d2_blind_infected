#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <left4dhooks>


public Plugin myinfo = {
    name        = "VersusBlindInfected",
    author      = "CanadaRox, TouchMe",
    description = "Hides all items from the infected team until they are (possibly) visible to one of the survivors to prevent exploration of the map",
    version     = "build0003",
    url         = "https://github.com/TouchMe-Inc/l4d2_blind_infected"
};


#define TEAM_SURVIVOR           2
#define TEAM_INFECTED           3

#define ENT_CHECK_INTERVAL      1.0
#define TRACE_TOLERANCE         75.0
#define ENTITY_NAME_SIZE        32


ArrayList g_hHiddenEntities = null;


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
    EngineVersion engine = GetEngineVersion();

    if (engine != Engine_Left4Dead2)
    {
        strcopy(sErr, iErrLen, "Plugin only supports Left 4 Dead 2");
        return APLRes_SilentFailure;
    }

    return APLRes_Success;
}

public void OnPluginStart()
{
    g_hHiddenEntities = CreateArray();

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

    CreateTimer(ENT_CHECK_INTERVAL, Timer_EntCheck, .flags = TIMER_REPEAT);
}

void Event_RoundStart(Event event, const char[] sEventName, bool bDontBroadcast)
{
    ClearArray(g_hHiddenEntities);

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
    int iEntityCount = GetEntityCount();

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

        PushArrayCell(g_hHiddenEntities, EntIndexToEntRef(iEnt));

        SDKHook(iEnt, SDKHook_SetTransmit, Hook_SetTransmit);
    }

    CloseHandle(hPlayerItems);
}

Action Timer_EntCheck(Handle hTimer)
{
    int iAliveSurvivors[MAXPLAYERS + 1];
    int iAliveSurvivorsCount = 0;
    for (int iClient = 1; iClient <= MaxClients; iClient++)
    {
        if (IsClientInGame(iClient) && IsClientSurvivor(iClient) && IsPlayerAlive(iClient)) {
            iAliveSurvivors[iAliveSurvivorsCount ++] = iClient;
        }
    }

    for (int iIndex = GetArraySize(g_hHiddenEntities) - 1; iIndex >= 0; iIndex --)
    {
        int iEntityRef = GetArrayCell(g_hHiddenEntities, iIndex);
        int iEntity = EntRefToEntIndex(iEntityRef);
    
        if (iEntity == INVALID_ENT_REFERENCE) {
            continue;
        }

        for (int iSurvivorIndex = 0; iSurvivorIndex < iAliveSurvivorsCount; iSurvivorIndex++)
        {
            if (IsClientSeeEntity(iAliveSurvivors[iSurvivorIndex], iEntity))
            {
                RemoveFromArray(g_hHiddenEntities, iIndex);
                break;
            }
        }
    }

    return Plugin_Continue;
}

Action Hook_SetTransmit(int iTransmitEntity, int iClient)
{
    if (!IsClientInfected(iClient)) {
        return Plugin_Continue;
    }

    for (int iIndex = GetArraySize(g_hHiddenEntities) - 1; iIndex >= 0; iIndex --)
    {
        int iEntityRef = GetArrayCell(g_hHiddenEntities, iIndex);
        int iEntity = EntRefToEntIndex(iEntityRef);
    
        if (iEntity == iTransmitEntity) {
            return Plugin_Handled;
        }
    }

    return Plugin_Continue;
}

/**
 * Check an entity for being visible to a client.
 */
bool IsClientSeeEntity(int iClient, int iEntity)
{
    float vClientOrigin[3]; GetClientEyePosition(iClient, vClientOrigin);
    float vEntOrigin[3]; GetEntPropVector(iEntity, Prop_Send, "m_vecOrigin", vEntOrigin);
    float vLookAt[3]; MakeVectorFromPoints(vClientOrigin, vEntOrigin, vLookAt);
    float vAngles[3]; GetVectorAngles(vLookAt, vAngles);

    Handle hTrace = TR_TraceRayFilterEx(vClientOrigin, vAngles, MASK_SHOT, RayType_Infinite, Filter_OnlyPhysics);

    bool bIsVisible = true;

    if (TR_DidHit(hTrace))
    {
        float vEndPosition[3]; TR_GetEndPosition(vEndPosition, hTrace);

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

    char szClassname[ENTITY_NAME_SIZE];
    GetEdictClassname(iEnt, szClassname, sizeof(szClassname));

    return (strcmp(szClassname, "prop_physics", false) != 0);
}

bool IsClientInfected(int iClient) {
    return (GetClientTeam(iClient) == TEAM_INFECTED);
}

bool IsClientSurvivor(int iClient) {
    return (GetClientTeam(iClient) == TEAM_SURVIVOR);
}
