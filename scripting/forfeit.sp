/**
 * vim: set ts=4 :
 * =============================================================================
 * SourceMod Rock The Vote Plugin
 * Creates a map vote when the required number of players have requested one.
 *
 * SourceMod (C)2004-2008 AlliedModders LLC.  All rights reserved.
 * =============================================================================
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 * 
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * As a special exception, AlliedModders LLC gives you permission to link the
 * code of this program (as well as its derivative works) to "Half-Life 2," the
 * "Source Engine," the "SourcePawn JIT," and any Game MODs that run on software
 * by the Valve Corporation.  You must obey the GNU General Public License in
 * all respects for all other code used.  Additionally, AlliedModders LLC grants
 * this exception to all derivative works.  AlliedModders LLC defines further
 * exceptions, found in LICENSE.txt (as of this writing, version JULY-31-2007),
 * or <http://www.sourcemod.net/license.php>.
 *
 * Version: $Id$
 */

#include <entity>
#include <sourcemod>
#include <tf2_stocks>
#include <logging>

#pragma semicolon 1
#pragma newdecls required

#define TEAM_COUNT 2
#define TEAM_OFFSET 2
#define CHAT_PREFIX "[SM] "

public Plugin myinfo =
{
	name = "Forfeit",
	author = "Doclic & AlliedModders LLC",
	description = "A plugin that allows team to forfeit games (Based on RTV)",
	version = "1.0"
};

ConVar g_Cvar_Needed;
ConVar g_Cvar_MinPlayers;
ConVar g_Cvar_InitialDelay;
ConVar g_Cvar_NextMap;

int g_Voters[TEAM_COUNT];				// Total voters connected. Doesn't include fake clients.
int g_Votes[TEAM_COUNT];				// Total number of "say rtv" votes
int g_VotesNeeded[TEAM_COUNT];			// Necessary votes before map vote begins. (voters * percent_needed)
int g_VoteTime;			// Used for sm_ff_initialdelay
bool g_Voted[MAXPLAYERS + 1] = {false, ...};

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("forfeit.phrases");
	
	g_Cvar_Needed = CreateConVar("sm_ff_needed", "0.66", "Percentage of players needed to forfeit (Def 66%)", 0, true, 0.05, true, 1.0);
	g_Cvar_MinPlayers = CreateConVar("sm_ff_minplayers", "12", "Number of players required before teams can forfeit.", 0, true, 0.0, true, float(MAXPLAYERS));
	g_Cvar_InitialDelay = CreateConVar("sm_ff_initialdelay", "180.0", "Time (in seconds) before a team can forfeit", 0, true, 0.00);
	g_Cvar_NextMap = FindConVar("sm_nextmap");
	if (g_Cvar_NextMap == null) g_Cvar_NextMap = FindConVar("nextmap");
	
	RegConsoleCmd("sm_f", Command_Forfeit);
	RegConsoleCmd("sm_forfeit", Command_Forfeit);
	
	//AutoExecConfig(true, "forfeit");

	//OnMapEnd();

    HookEvent("teamplay_round_start", OnRoundStart, EventHookMode_Pre);
    HookEvent("teamplay_round_win", OnRoundEnd, EventHookMode_Pre);
    HookEvent("teamplay_round_stalemate", OnRoundEnd, EventHookMode_Pre);
    HookEvent("player_team", OnTeamChange, EventHookMode_Pre);

	/* Handle late load */
	for (int i=1; i<=MaxClients; i++)
	{
		if (IsClientConnected(i))
		{
			OnClientConnected(i);	
		}	
	}
}

public Action OnRoundStart(Handle hEvent, const char[] sName, bool bDontBroadcast)
{
	g_VoteTime = GetTime() + g_Cvar_InitialDelay.IntValue;
	for(int i = 0; i < TEAM_COUNT; i++) {
		g_Votes[i] = 0;
	}
	
	for(int iClient = 1; iClient < MaxClients; iClient++)
		if (IsClientInGame(iClient))
			g_Voted[iClient] = false;

	return Plugin_Continue;
}

public Action OnRoundEnd(Handle hEvent, const char[] sName, bool bDontBroadcast)
{
	g_VoteTime = GetTime() + 999; // very clean and efficient way to prevent more ffs
	for(int i = 0; i < TEAM_COUNT; i++) {
		g_Votes[i] = 0;
	}

	return Plugin_Continue;
}

/*public void OnMapEnd()
{
	g_Voters = 0;
}*/

public Action OnTeamChange(Handle hEvent, const char[] sName, bool bDontBroadcast) {
	int iClient = GetClientOfUserId(GetEventInt(hEvent, "userid"));
	TFTeam iNew = view_as<TFTeam>(GetEventInt(hEvent, "team"));
	TFTeam iOld = view_as<TFTeam>(GetEventInt(hEvent, "oldteam"));
	
	HandleTeamLeave(iClient, iOld);
	HandleTeamJoin(iClient, iNew);

	return Plugin_Continue;
}

public void OnClientConnected(int iClient)
{
	if (!IsFakeClient(iClient))
	{
		g_Voted[iClient] = false;
	}
}

public void OnClientDisconnect(int client)
{	
	TFTeam iTeam = TF2_GetClientTeam(client);
	//HandleTeamLeave(client, iTeam);
	int iOffsetTeam = iTeam - TEAM_OFFSET;
	
	if (g_Votes[iOffsetTeam] && 
		g_Voters[iOffsetTeam] && 
		g_Votes[iOffsetTeam] >= g_VotesNeeded[iOffsetTeam]) 
	{
		Forfeit_MakeTeamLose(iTeam);
	}	
}
public void HandleTeamJoin(int iClient, TFTeam iTeam)
{
	if (!Forfeit_IsValidTeam(iTeam)) return;
	int iOffsetTeam = iTeam - TEAM_OFFSET;

	g_Voters[iOffsetTeam]++;
	if (!IsFakeClient(iClient))
	{
		g_VotesNeeded[iOffsetTeam] = RoundToCeil(float(g_Voters[iOffsetTeam]) * g_Cvar_Needed.FloatValue);
	}

	// Logs
	char sName[64];
	GetClientName(iClient, sName, sizeof(sName));
	LogMessage("%s joined team id %i (debug: %d %i)", sName, iTeam, g_VotesNeeded[iOffsetTeam], g_Voters[iOffsetTeam]);
}

public void HandleTeamLeave(int iClient, TFTeam iTeam) {
	if (!Forfeit_IsValidTeam(iTeam)) return;
	int iOffsetTeam = iTeam - TEAM_OFFSET;

	g_Voters[iOffsetTeam]--;
	if (g_Voted[iClient])
	{
		g_Votes[iOffsetTeam]--;
		g_Voted[iClient] = false;
	}
	
	if (!IsFakeClient(iClient))
	{
		g_VotesNeeded[iOffsetTeam] = RoundToCeil(float(g_Voters[iOffsetTeam]) * g_Cvar_Needed.FloatValue);
	}

	// Logs
	char sName[64];
	GetClientName(iClient, sName, sizeof(sName));
	LogMessage("%s has left team id %i (debug: %d %i)", sName, iTeam, g_VotesNeeded[iOffsetTeam], g_Voters[iOffsetTeam]);
}

public Action Command_Forfeit(int client, int args)
{
	if (!client)
	{
		return Plugin_Handled;
	}
	
	AttemptRTV(client);
	
	return Plugin_Handled;
}

void AttemptRTV(int client)
{
	TFTeam iTeam = TF2_GetClientTeam(client);
	if (!Forfeit_IsValidTeam(iTeam)) return; // maybe add a message
	int iOffsetTeam = iTeam - TEAM_OFFSET;

	if (g_VoteTime > GetTime())
	{
		ReplyToCommand(client, CHAT_PREFIX ... "%t", "Forfeit Not Allowed");
		return;
	}
	
	if (GetClientCount(true) < g_Cvar_MinPlayers.IntValue)
	{
		ReplyToCommand(client, CHAT_PREFIX ... "%t", "Minimal Players Not Met");
		return;			
	}
	
	if (g_Voted[client])
	{
		ReplyToCommand(client, CHAT_PREFIX ... "%t", "Already Voted", g_Votes[iOffsetTeam], g_VotesNeeded[iOffsetTeam]);
		return;
	}	
	
	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));
	
	g_Votes[iOffsetTeam]++;
	g_Voted[client] = true;
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			TFTeam iClientTeam = TF2_GetClientTeam(i);
			/*SetGlobalTransTarget(i);
			VFormat(buffer, sizeof(buffer), format, 2);*/
			char sTranslate[32];
			if (iClientTeam == iTeam) {
				sTranslate = "Forfeit Requested";
			} else {
				sTranslate = "Forfeit Requested Enemy";
			}
			PrintToChat(i, CHAT_PREFIX ... "%t", sTranslate, Forfeit_GetTeamName(iTeam), name, g_Votes[iOffsetTeam], g_VotesNeeded[iOffsetTeam]);
		}
	}
	//PrintToChatAll(CHAT_PREFIX ... "%t", "Forfeit Requested", Forfeit_GetTeamName(iTeam), name, g_Votes[iOffsetTeam], g_VotesNeeded[iOffsetTeam]);
	
	if (g_Votes[iOffsetTeam] >= g_VotesNeeded[iOffsetTeam])
	{
		Forfeit_MakeTeamLose(iTeam);
	}	
}

public void Forfeit_MakeTeamLose(TFTeam iLosing)
{
	if (!Forfeit_IsValidTeam(iLosing)) return;

	TFTeam iTeam = iLosing == TFTeam_Red ? TFTeam_Blue : TFTeam_Red;

	PrintToChatAll(CHAT_PREFIX ... "%t", "Team Forfeit", Forfeit_GetTeamName(iLosing));
	SetHudTextParams(-1.0, 0.3, 15.0, 255, 0, 0, 255, 0, _, 0.0, 0.0);
	for(int iClient = 1; iClient < MaxClients; iClient++)
		if (IsClientInGame(iClient))
			ShowHudText(iClient, -1, "%t", "Team Forfeit Center", Forfeit_GetTeamName(iLosing));

	
	int iEnt = -1;
	iEnt = FindEntityByClassname(iEnt, "team_control_point_master");
	
	if (iEnt < 1)
	{
		iEnt = CreateEntityByName("team_control_point_master");

		if (IsValidEntity(iEnt)){
			DispatchSpawn(iEnt);
        	AcceptEntityInput(iEnt, "Enable");
		}
		else
		{
			PrintToChatAll(CHAT_PREFIX ... "%t", "Cannot Force Win");
		}
	}

	SetEntProp(iEnt, Prop_Data, "m_bPlayAllRounds", false);
		
	SetVariantInt(iTeam);
	AcceptEntityInput(iEnt, "SetWinner");

	CreateTimer(10.0, Timer_NextMap);

	
	/*for(int iClient = 1; iClient < MAXPLAYERS; iClient++)
		if (!IsFakeClient(iClient))
			g_Voters[TF2_GetClientTeam(iClient) - TEAM_OFFSET]++;*/

			
	for(int iTeam = 0; iTeam < TEAM_COUNT; iTeam++) {
		g_Votes[iTeam] = 0;
		g_Voters[iTeam]++;
	}
}

public bool Forfeit_IsValidTeam(TFTeam iTeam) {
	return iTeam == TFTeam_Red || iTeam == TFTeam_Blue;
}

char[] Forfeit_GetTeamName(TFTeam iTeam) {
	char str[4];

	switch(iTeam) {
		case TFTeam_Blue: {
			str = "BLU";
		}
		case TFTeam_Red: {
			str = "RED";
		}
		default: {
			str = "???";
		}
	}

	return str;
}

public Action Timer_NextMap(Handle timer)
{
	char s_NextMap[64];
	g_Cvar_NextMap.GetString(s_NextMap, sizeof(s_NextMap));
    ServerCommand("changelevel %s", s_NextMap);
}
