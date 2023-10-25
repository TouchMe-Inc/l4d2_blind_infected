#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>


public Plugin myinfo =
{
	name = "VersusBlindInfected",
	author = "CanadaRox, TouchMe",
	description = "Hides all items from the infected team until they are (possibly) visible to one of the survivors to prevent exploration of the map",
	version = "build0000",
	url = "https://github.com/TouchMe-Inc/l4d2_blind_infected"
};


#define TEAM_SURVIVOR           2
#define TEAM_INFECTED           3

#define ENT_CHECK_INTERVAL      1.0
#define TRACE_TOLERANCE         75.0
#define ENTITY_NAME_SIZE        64

#define ENT_REF                 0
#define CAN_SEE                 1
#define ARRAY_SIZE              2


int g_iHiddenEntitiesSize = 0;

Handle g_hHiddenEntities = INVALID_HANDLE;

Handle g_hTimer = INVALID_HANDLE;


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
	g_hHiddenEntities = CreateArray(ARRAY_SIZE);

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
}

public void OnPluginEnd() {
	CloseHandle(g_hHiddenEntities);
}

void Event_RoundStart(Event event, const char[] sEventName, bool bDontBroadcast)
{
	ClearArray(g_hHiddenEntities);

	char iEntClassname[ENTITY_NAME_SIZE];
	int iHiddenEntity[ARRAY_SIZE], iEntityCount = GetEntityCount();

	for (int iEnt = (MaxClients + 1); iEnt < iEntityCount; iEnt ++)
	{
		if (!IsValidEntity(iEnt) || !IsValidEdict(iEnt)) {
			continue;
		}
	
		GetEdictClassname(iEnt, iEntClassname, sizeof(iEntClassname));

		if (strcmp(iEntClassname, "weapon_") == -1) {
			continue;
		}

		SDKHook(iEnt, SDKHook_SetTransmit, OnTransmit);

		iHiddenEntity[ENT_REF] = EntIndexToEntRef(iEnt);
		iHiddenEntity[CAN_SEE] = false;

		PushArrayArray(g_hHiddenEntities, iHiddenEntity, sizeof(iHiddenEntity));
	}

	g_iHiddenEntitiesSize = GetArraySize(g_hHiddenEntities);

	g_hTimer = CreateTimer(ENT_CHECK_INTERVAL, Timer_EntCheck, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_EntCheck(Handle hTimer)
{
	if (g_hTimer == INVALID_HANDLE) {
		return Plugin_Stop;
	}

	int iHiddenEntity[ARRAY_SIZE], iEntity;

	for (int iIndex = 0; iIndex < g_iHiddenEntitiesSize; iIndex ++)
	{
		GetArrayArray(g_hHiddenEntities, iIndex, iHiddenEntity, sizeof(iHiddenEntity));

		if ((iEntity = EntRefToEntIndex(iHiddenEntity[ENT_REF])) == INVALID_ENT_REFERENCE) {
			continue;
		}

		if (!iHiddenEntity[CAN_SEE] && IsAnySurvivorSeeEntity(iEntity))
		{
			iHiddenEntity[CAN_SEE] = true;

			SetArrayArray(g_hHiddenEntities, iIndex, iHiddenEntity, sizeof(iHiddenEntity));
		}
	}

	return Plugin_Continue;
}

void Event_RoundEnd(Event event, const char[] sEventName, bool bDontBroadcast) {
	g_hTimer = INVALID_HANDLE;
}

Action OnTransmit(int iEntity, int iClient)
{
	if (!IsClientInfected(iClient)) {
		return Plugin_Continue;
	}

	int iHiddenEntity[ARRAY_SIZE];

	for (int iIndex = 0; iIndex < g_iHiddenEntitiesSize; iIndex ++)
	{
		GetArrayArray(g_hHiddenEntities, iIndex, iHiddenEntity, sizeof(iHiddenEntity));

		if (iEntity == EntRefToEntIndex(iHiddenEntity[ENT_REF])) {
			return (iHiddenEntity[CAN_SEE]) ? Plugin_Continue : Plugin_Handled;
		}
	}

	return Plugin_Continue;
}

bool IsAnySurvivorSeeEntity(int iEntity)
{
	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (IsClientInGame(iClient)
		&& IsClientSurvivor(iClient) && IsPlayerAlive(iClient)
		&& IsClientSeeEntity(iClient, iEntity)) {
			return true;
		}
	}

	return false;
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

	char sClassName[ENTITY_NAME_SIZE];
	GetEdictClassname(iEnt, sClassName, sizeof(sClassName));

	return (strcmp(sClassName, "prop_physics", false) != 0);
}

/**
 * Infected team player?
 */
bool IsClientInfected(int iClient) {
	return (GetClientTeam(iClient) == TEAM_INFECTED);
}

/**
 * Survivor team player?
 */
bool IsClientSurvivor(int iClient) {
	return (GetClientTeam(iClient) == TEAM_SURVIVOR);
}
