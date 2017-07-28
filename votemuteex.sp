/*
 * Vote Mute EX.
 * by: shanapu
 * https://github.com/shanapu/VoteMuteEX/
 * 
 * Copyright (C) 2017 Thomas Schmidt (shanapu)
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 * 
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 */


#include <sourcemod>
#include <sdktools>
#include <voiceannounce_ex>
#include <colors>

#undef REQUIRE_PLUGIN
#include <sourcecomms>
#include <basecomm>
#define REQUIRE_PLUGIN


#pragma semicolon 1
#pragma newdecls required


Handle g_hTimerSpeak[MAXPLAYERS+1];
Handle g_hTimerVoting;

char g_sChatPrefix[64];
char g_sRestrictedSound[32] = "buttons/button11.wav";
char g_sSuccessSound[32] = "ui/buttonclick.wav";

bool g_bProgess = false;

bool g_bSpeak[MAXPLAYERS+1] = false;
bool g_bVoted[MAXPLAYERS+1] = false;

int g_iSpeakers = 0;
int g_iTarget = -1;
int g_iVotersAll = 0;
int g_iVotersYes = 0;
int g_iVotersNo = 0;
int g_iCooldown[MAXPLAYERS+1];


ConVar gc_bPlugin;
ConVar gc_fTime;
ConVar gc_bAdmins;
ConVar gc_fVoteTime;
ConVar gc_iVotePercent;
ConVar gc_iMuteLength;
ConVar gc_sChatPrefix;
ConVar gc_bCleanMenu;
ConVar gc_bAdminsExclude;
ConVar gc_sCustomCommand;
ConVar gc_iCooldown;


public Plugin myinfo =
{
	name = "VoteMuteEX",
	author = "shanapu",
	description = "",
	version = "1.2",
	url = "https://github.com/shanapu"
};


public void OnPluginStart()
{
	RegConsoleCmd("sm_votemute", Command_VoteMute, "Start a vote to mute a player");
	//RegConsoleCmd("sm_testmute", Command_TestMute, "");

	gc_bPlugin = CreateConVar("sm_votemute_ex_enable", "1", "0 - disabled, 1 - enable plugin", _, true, 0.0, true, 1.0);
	gc_fTime = CreateConVar("sm_votemute_ex_time", "45", "Time to show player stop talking", _, true, 0.0);
	gc_bAdmins = CreateConVar("sm_votemute_ex_admins", "0", "0 - all player can start vote, 1 - only admins can start a vote", _, true, 0.0, true, 1.0);
	gc_bAdminsExclude = CreateConVar("sm_votemute_ex_admins_exclude", "1", "0 - show admin, too, 1 - only non-admin", _, true, 0.0, true, 1.0);
	gc_fVoteTime = CreateConVar("sm_votemute_ex_vote_time", "25", "Time the vote is active", _, true, 5.0);
	gc_iVotePercent = CreateConVar("sm_votemute_ex_percent", "50", "how many percent of the players have to vote yes", _, true, 1.0, true, 100.0);
	gc_iMuteLength = CreateConVar("sm_votemute_ex_length", "10", "how many minutes should a player be muted (only with sourcecomms!) -1 = muting client for session. Permanent (0) is not allowed at this time. by sourcecomms", _, true, -1.0, true, 100.0);
	gc_iCooldown = CreateConVar("sm_votemute_ex_cooldown", "30", "Command cooldown to prevent voting spam in seconds", _, true, 0.0);
	gc_sChatPrefix = CreateConVar("sm_votemute_ex_prefix", "[{green}VoteMute{default}]", "Set chat prefix");
	gc_bCleanMenu = CreateConVar("sm_votemute_ex_menu", "1", "use 3. & 4. for yes/no instead of 1. & 2.", _, true, 0.0, true, 1.0);
	gc_sCustomCommand = CreateConVar("sm_votemute_ex_cmds", "vmute, vm", "Set your custom chat command for !votemute (no 'sm_'/'!')(seperate with comma ', ')(max. 12 commands)");

	AutoExecConfig(true, "VoteMuteEx");
}

public void OnConfigsExecuted()
{
	gc_sChatPrefix.GetString(g_sChatPrefix, sizeof(g_sChatPrefix));

	// Set custom Commands
	int iCount = 0;
	char sCommands[128], sCommandsL[12][32], sCommand[32];

	gc_sCustomCommand.GetString(sCommands, sizeof(sCommands));
	ReplaceString(sCommands, sizeof(sCommands), " ", "");
	iCount = ExplodeString(sCommands, ",", sCommandsL, sizeof(sCommandsL), sizeof(sCommandsL[]));

	for (int i = 0; i < iCount; i++)
	{
		Format(sCommand, sizeof(sCommand), "sm_%s", sCommandsL[i]);
		if (GetCommandFlags(sCommand) == INVALID_FCVAR_FLAGS)  // if command not already exist
			RegConsoleCmd(sCommand, Command_VoteMute, "Start a vote to mute a player");
	}
}

public Action Command_TestMute(int client, int args)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		OnClientSpeakingEx(i);
		OnClientSpeakingEnd(i);
	}
}

public Action Command_VoteMute(int client, int args)
{
	if (!gc_bPlugin.BoolValue)
	{
		CReplyToCommand(client, "%s Plugin is disabled", g_sChatPrefix);

		return Plugin_Handled;
	}

	if (gc_bAdmins.BoolValue && !CheckCommandAccess(client, "sm_votemute_ex_overwrite", ADMFLAG_KICK, false))
	{
		CReplyToCommand(client, "%s You must be an admin to use this command", g_sChatPrefix);

		return Plugin_Handled;
	}

	if (g_iSpeakers <= 0 || (g_iSpeakers == 1 && g_bSpeak[client]))
	{
		CReplyToCommand(client, "%s No one has spoken in last %i seconds", g_sChatPrefix, RoundToCeil(gc_fTime.FloatValue));

		return Plugin_Handled;
	}

	if(g_bProgess)
	{
		CReplyToCommand(client, "%s There is already a vote in progress", g_sChatPrefix);

		return Plugin_Handled;
	}

	if (g_iCooldown[client] != -1 && g_iCooldown[client] > GetTime())
	{
		CReplyToCommand(client, "%s You can't reuse this command immediately, please wait", g_sChatPrefix);
		return Plugin_Handled;
	}

	Menu_VoteMute(client);

	return Plugin_Handled;
}

void Menu_VoteMute(int client)
{
	char buffer[255];
	Menu menu = new Menu(Handler_VoteMute);

	Format(buffer, sizeof(buffer), "VoteMute - Choose a player");
	menu.SetTitle(buffer);

	for (int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && g_bSpeak[i] && client != i)
		{
			if (CheckCommandAccess(i, "sm_votemute_ex_overwrite", ADMFLAG_KICK, false) && gc_bAdminsExclude.BoolValue)
			{
				continue;
			}
			
			Format(buffer, sizeof(buffer), "%N", i);

			char userid[11];
			IntToString(GetClientUserId(i), userid, sizeof(userid));

			menu.AddItem(userid, buffer);
		}
		
		g_bVoted[i] = false;
	}

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}


public int Handler_VoteMute(Menu menu, MenuAction action, int client, int selection)
{
	if (action == MenuAction_Select)
	{
		char buffer[32];
		menu.GetItem(selection, buffer, sizeof(buffer));
		g_iTarget = StringToInt(buffer);
		int target = GetClientOfUserId(g_iTarget);

		if(!IsClientInGame(target))
		{
			CPrintToChat(client, "%s Player has left the game", g_sChatPrefix);
			delete menu;
		}

		g_iVotersAll = 2;
		g_iVotersYes = 0;
		g_iVotersNo = 1;

		g_hTimerVoting = CreateTimer(gc_fVoteTime.FloatValue, Timer_Voting);

		g_bProgess = true;

		g_iCooldown[client] = GetTime() + gc_iCooldown.IntValue;

		for (int i = 1; i <= MaxClients; i++) if (target != i)
		{
			Menu_VotePlayer(i, client, target);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
}


void Menu_VotePlayer(int client, int starter, int target)
{
	char buffer[255];
	Menu menu = new Menu(Handler_VotePlayer);

	Format(buffer, sizeof(buffer), "%N started a VoteMute against %N\n", starter, target);
	menu.SetTitle(buffer);

	if(gc_bCleanMenu.BoolValue)
	{
		menu.AddItem("1", "0", ITEMDRAW_SPACER);
		menu.AddItem("1", "0", ITEMDRAW_SPACER);
	}

	Format(buffer, sizeof(buffer), "Mute him");
	menu.AddItem("1", buffer);
	
	Format(buffer, sizeof(buffer), "Don't mute");
	menu.AddItem("0", buffer);

	menu.ExitButton = true;
	menu.Display(client, RoundToCeil(gc_fVoteTime.FloatValue));
}


public int Handler_VotePlayer(Menu menu, MenuAction action, int client, int selection)
{
	if (action == MenuAction_Select)
	{
		char buffer[32];
		menu.GetItem(selection, buffer, sizeof(buffer));

		int choice = StringToInt(buffer);
		if (choice == 1)
		{
			g_iVotersYes++;
		}
		else if (choice == 0)
		{
			g_iVotersNo++;
		}

		g_iVotersAll++;
		g_bVoted[client] = true;

		CheckVotes();

	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
}

void CheckVotes()
{
	int threshold = RoundToCeil(GetClientCount(true) * (gc_iVotePercent.IntValue / 100.0));
	int negThreshold = GetClientCount(true) - threshold;
	int target = GetClientOfUserId(g_iTarget);
	char buffer[255];

	if (g_iVotersYes >= threshold)
	{

		if (GetFeatureStatus(FeatureType_Native, "SourceComms_SetClientMute") == FeatureStatus_Available)
		{
			Format(buffer, sizeof(buffer), "Muted through VoteMuteEX with %i YES & %i NO votes", g_iVotersYes, g_iVotersNo);
			SourceComms_SetClientMute(target, true, gc_iMuteLength.IntValue , true, buffer);

		}
		else
		{
			BaseComm_SetClientMute(target, true);
			SetClientListeningFlags(target, VOICE_MUTED);
		}
		
		CPrintToChat(target, "%s You was muted by vote", g_sChatPrefix);
		
		Format(buffer, sizeof(buffer), "VoteMute %N SUCCESSFULL:\nYES votes: %i\nNO votes: %i\nVotes NEEDED: %i", target, g_iVotersYes, g_iVotersNo, threshold);

		for (int i = 1; i <= MaxClients; i++)
		{
			if(IsClientInGame(i))
			{
				Menu_SendInterim(i, buffer);
				ClientCommand(i, "play %s", g_sSuccessSound);
			}
		}

		delete g_hTimerVoting;
		g_bProgess = false;
	}
	else if (g_iVotersNo >= negThreshold)
	{
		Format(buffer, sizeof(buffer), "VoteMute %N FAILED:\nYES votes: %i\nNO votes: %i\nVotes NEEDED: %i", target, g_iVotersYes, g_iVotersNo, threshold);

		
		
		for (int i = 1; i <= MaxClients; i++)
		{
			if(IsClientInGame(i))
			{
				Menu_SendInterim(i, buffer);
				ClientCommand(i, "play %s", g_sRestrictedSound);
			}
		}

		delete g_hTimerVoting;
		g_bProgess = false;
	}
	else
	{
		Format(buffer, sizeof(buffer), "VoteMute %N interim:\nYES votes: %i\nNO votes: %i\n\nVotes NEEDED: %i", target, g_iVotersYes, g_iVotersNo, threshold);

		for (int i = 1; i <= MaxClients; i++)
		{
			if(IsClientInGame(i) && g_bVoted[i])
			{
				Menu_SendInterim(i, buffer);
			}
		}

	}
}


void Menu_SendInterim(int client, char [] buffer)
{
	Menu menu = new Menu(Handler_Empty);

	menu.SetTitle(buffer);

	menu.AddItem("1", "0", ITEMDRAW_SPACER);

	menu.ExitButton = true;
	menu.Display(client, RoundToCeil(gc_fVoteTime.FloatValue));
}


public int Handler_Empty(Menu menu, MenuAction action, int client, int selection)
{
}

public void OnClientPutInServer(int client)
{
	g_iCooldown[client] = -1;
	g_bSpeak[client] = false;
	g_bVoted[client] = false;
}

public void OnClientDisconnect(int client)
{
	delete g_hTimerSpeak[client];

	g_bSpeak[client] = false;
	g_iSpeakers--;
}


public void OnClientSpeakingEx(int client)
{
	g_bSpeak[client] = true;
	g_iSpeakers++;

	delete g_hTimerSpeak[client];
}


public void OnClientSpeakingEnd(int client)
{
	delete g_hTimerSpeak[client];

	g_hTimerSpeak[client] = CreateTimer(gc_fTime.FloatValue, Timer_SpeakEnd, client);
}


public Action Timer_SpeakEnd(Handle timer, int client)
{
	g_hTimerSpeak[client] = null;
	g_bSpeak[client] = false;
	g_iSpeakers--;
}


public Action Timer_Voting(Handle timer)
{
	char buffer[256];
	int threshold = RoundToCeil(GetClientCount(true) * (gc_iVotePercent.IntValue / 100.0));
	Format(buffer, sizeof(buffer), "VoteMute %N ENDED without enough voters:\nYES votes: %i\nNO votes: %i\nVotes NEEDED: %i", GetClientOfUserId(g_iTarget), g_iVotersYes, g_iVotersNo, threshold);

	for (int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i))
		{
			Menu_SendInterim(i, buffer);
			ClientCommand(i, "play %s", g_sRestrictedSound);
		}
	}

	g_hTimerVoting = null;
	g_bProgess = false;
	g_iTarget = -1;
}