/var/const/OPEN = 1
/var/const/CLOSED = 2

var/global/list/alert_overlays_global = list()

/proc/convert_k2c(var/temp)
	return ((temp - T0C)) // * 1.8) + 32

/proc/convert_c2k(var/temp)
	return ((temp + T0C)) // * 1.8) + 32

/proc/getCardinalAirInfo(var/atom/source, var/turf/loc, var/list/stats=list("temperature"))
	var/list/temps = new/list(4)
	for(var/dir in cardinal)
		var/direction
		switch(dir)
			if(NORTH)
				direction = 1
			if(SOUTH)
				direction = 2
			if(EAST)
				direction = 3
			if(WEST)
				direction = 4
		var/turf/simulated/T=get_turf(get_step(loc,dir))
		if(dir == turn(source.dir, 180) && source.flags & ON_BORDER)
			T = get_turf(source)
		var/list/rstats = new /list(stats.len)
		if(T && istype(T) && T.zone)
			var/datum/gas_mixture/environment = T.return_air()
			for(var/i=1;i<=stats.len;i++)
				rstats[i] = environment.vars[stats[i]]
		else if(istype(T, /turf/simulated))
			rstats = null // Exclude zone (wall, door, etc).
		else if(istype(T, /turf))
			// Should still work.  (/turf/return_air())
			var/datum/gas_mixture/environment = T.return_air()
			for(var/i=1;i<=stats.len;i++)
				rstats[i] = environment.vars[stats[i]]
		temps[direction] = rstats
	return temps

#define FIREDOOR_MAX_PRESSURE_DIFF 25 // kPa
#define FIREDOOR_MAX_TEMP 50 // �C
#define FIREDOOR_MIN_TEMP 0

// Bitflags
#define FIREDOOR_ALERT_HOT      1
#define FIREDOOR_ALERT_COLD     2
// Not used #define FIREDOOR_ALERT_LOWPRESS 4

#define FIREDOOR_CLOSED_MOD	0.8

/obj/machinery/door/firedoor
	name = "firelock"
	desc = "Apply crowbar."
	icon = 'icons/obj/doors/Doorfireglass.dmi'
	icon_state = "door_open"
	opacity = 0
	density = 0
	heat_proof = 1
	glass = 1
	layer = DOOR_LAYER - 0.2
	base_layer = DOOR_LAYER - 0.2

	dir = 2

	var/list/alert_overlays_local

	var/blocked = 0
	var/lockdown = 0 // When the door has detected a problem, it locks.
	var/pdiff_alert = 0
	var/pdiff = 0
	var/nextstate = null
	var/net_id
	var/list/areas_added
	var/list/users_to_open
	var/list/tile_info[4]
	var/list/dir_alerts[4] // 4 dirs, bitflags

	// MUST be in same order as FIREDOOR_ALERT_*
	var/list/ALERT_STATES=list(
		"hot",
		"cold"
	)



/obj/machinery/door/firedoor/New()
	. = ..()

	if(!("[src.type]" in alert_overlays_global))
		alert_overlays_global += list("[src.type]" = list("alert_hot" = list(),
														"alert_cold" = list())
									)

		var/list/type_states = alert_overlays_global["[src.type]"]

		for(var/alert_state in type_states)
			var/list/starting = list()
			for(var/cdir in cardinal)
				starting["[cdir]"] = icon(src.icon, alert_state, dir = cdir)
			type_states[alert_state] = starting
		alert_overlays_global["[src.type]"] = type_states
		alert_overlays_local = type_states
	else
		alert_overlays_local = alert_overlays_global["[src.type]"]

	for(var/obj/machinery/door/firedoor/F in loc)
		if(F != src)
			if(F.flags & ON_BORDER && src.flags & ON_BORDER && F.dir != src.dir) //two border doors on the same tile don't collide
				continue
			spawn(1)
				qdel(src)
			return .
	var/area/A = get_area(src)
	ASSERT(istype(A))

	A.all_doors.Add(src)
	areas_added = list(A)

	for(var/direction in cardinal)
		A = get_area(get_step(src,direction))
		if(istype(A) && !(A in areas_added))
			A.all_doors.Add(src)
			areas_added += A

/obj/machinery/door/firedoor/examine(mob/user)
	. = ..()
	if(pdiff >= FIREDOOR_MAX_PRESSURE_DIFF)
		user << "<span class='danger'>WARNING: Current pressure differential is [pdiff]kPa! Opening door may result in injury!</span>"

	user << "<b>Sensor readings:</b>"
	for(var/index = 1; index <= tile_info.len; index++)
		var/o = "&nbsp;&nbsp;"
		switch(index)
			if(1)
				o += "NORTH: "
			if(2)
				o += "SOUTH: "
			if(3)
				o += "EAST: "
			if(4)
				o += "WEST: "
		if(tile_info[index] == null)
			o += "<span class='warning'>DATA UNAVAILABLE</span>"
			usr << o
			continue
		var/celsius = convert_k2c(tile_info[index][1])
		var/pressure = tile_info[index][2]
		if(dir_alerts[index] & (FIREDOOR_ALERT_HOT|FIREDOOR_ALERT_COLD))
			o += "<span class='warning'>"
		else
			o += "<span style='color:blue'>"
		o += "[celsius]�C</span> "
		o += "<span style='color:blue'>"
		o += "[pressure]kPa</span></li>"
		user << o

	if( islist(users_to_open) && users_to_open.len)
		var/users_to_open_string = users_to_open[1]
		if(users_to_open.len >= 2)
			for(var/i = 2 to users_to_open.len)
				users_to_open_string += ", [users_to_open[i]]"
		user << "These people have opened \the [src] during an alert: [users_to_open_string]."


/obj/machinery/door/firedoor/Destroy()
	for(var/area/A in areas_added)
		A.all_doors.Remove(src)
	. = ..()

/obj/machinery/door/firedoor/Bumped(atom/AM)
	if(p_open || operating)	return
	if(!density)	return ..()
	return 0


/obj/machinery/door/firedoor/power_change()
	if(powered(power_channel))
		stat &= ~NOPOWER
		latetoggle()
	else
		stat |= NOPOWER
	return


/obj/machinery/door/firedoor/attackby(obj/item/weapon/C as obj, mob/user as mob, params)
	add_fingerprint(user)
	if(operating)	return//Already doing something.
	if(istype(C, /obj/item/weapon/weldingtool))
		var/obj/item/weapon/weldingtool/W = C
		if(W.remove_fuel(0, user))
			blocked = !blocked
			user << text("<span class='danger'>You [blocked?"welded":"unwelded"] \the [src]</span>")
			update_icon()
			return

	if(istype(C, /obj/item/weapon/crowbar) || (istype(C,/obj/item/weapon/twohanded/fireaxe) && C:wielded == 1))
		if(blocked || operating)	return
		if(density)
			open()
			return
		else	//close it up again	//fucking 10/10 commenting here einstein //bravo nolan
			close()
			return
	return

/obj/machinery/door/firedoor/attack_ai(mob/user as mob)
	add_fingerprint(user)
	if(blocked || operating || stat & NOPOWER)
		return
	if(density)
		open()
	else
		close()
	return

/obj/machinery/door/firedoor/do_animate(animation)
	switch(animation)
		if("opening")
			flick("door_opening", src)
		if("closing")
			flick("door_closing", src)
	return


/obj/machinery/door/firedoor/update_icon()
	overlays.Cut()
	if(density)
		icon_state = "door_closed"
		if(blocked)
			overlays += "welded"
	else
		icon_state = "door_open"
		if(blocked)
			overlays += "welded_open"
	return

/obj/machinery/door/firedoor/open()
	..()
	latetoggle()
	return

/obj/machinery/door/firedoor/close()
	..()
	if(locate(/mob/living) in get_turf(src))
		open()
		return
	latetoggle()
	return

/obj/machinery/door/firedoor/proc/latetoggle()
	if(operating || stat & NOPOWER || !nextstate)
		return
	switch(nextstate)
		if(OPEN)
			nextstate = null
			open()
		if(CLOSED)
			nextstate = null
			close()
	return


/obj/machinery/door/firedoor/border_only
	icon = 'icons/obj/doors/edge_Doorfire.dmi'
	flags = ON_BORDER

/obj/machinery/door/firedoor/border_only/CanPass(atom/movable/mover, turf/target, height=0)
	if(istype(mover) && mover.checkpass(PASSGLASS))
		return 1
	if(get_dir(loc, target) == dir) //Make sure looking at appropriate border
		return !density
	else
		return 1

/obj/machinery/door/firedoor/border_only/CheckExit(atom/movable/mover as mob|obj, turf/target as turf)
	if(istype(mover) && mover.checkpass(PASSGLASS))
		return 1
	if(get_dir(loc, target) == dir)
		return !density
	else
		return 1


/obj/machinery/door/firedoor/heavy
	name = "heavy firelock"
	icon = 'icons/obj/doors/Doorfire.dmi'
	glass = 0


