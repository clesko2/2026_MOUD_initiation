/* Define library */
libname source 'S:/JHU_HIVcohorts/JHHCC/2024Q4' access=readonly;
libname target 'S:/JHU_HIVcohorts/Analyses_Chiu/opioid_2024/Data';

/* Folder path */
%let path=S:/JHU_HIVcohorts/Analyses_Chiu/opioid_2024/Data;

/* Copy source to working folder */
*Create list of source data sets;
proc sql noprint;
	create table table_list as
	select memname from dictionary.tables
	where libname='SOURCE';
quit;

*Copies source data into working folder and sorts by ID;
data _null_;
	set table_list;
	call execute(cat('proc sort data=source.', strip(memname), ' (encoding=any) out=', strip(scan(memname, 1, '_')), '; ', 'by id; run;'));
run;

/* Define cohort */
*Alive at index date, latest of (01-Jan-2012 or enrollment date after 01Jan2012);
*Note: 01-Jan-2012 was approximately the date that PWH universally began to receive HAART;
data cohort_step1;
	set flat;
	format index_date date9.;
	if dod > '01jan2012'd or missing(dod) then do; *Include only those living after 01Jan2012;
		index_date = max(starty, '01jan2012'd);
		dob = mdy(7, 1, birthyear);
		age = intck('year', dob, index_date, 'c'); *Impute age;
		incl_entry = 1;
	end;
	drop birthyear dob age0;
run;

proc sort data=cohort_step1;
	by id;
run;

*Get index OUD diagnosis (earliest diagnosis on or after the index date);
proc sql noprint;
	create table visit_type as
	select a.id, a.dx, a.diagnosisdate, b.encounterdate, b.encountertype
	from diagnoses as a
	inner join visits as b
	on a.id = b.id and a.diagnosisdate = b.encounterdate
	where apptstatus = 'Arrived';

	create table incl_dx_oud_prep as
	select distinct a.id, 1 as incl_dx_oud, min(diagnosisdate) as index_dx_date format=date9.
	from cohort_step1 as a
	inner join diagnoses as b
	on a.id = b.id and a.index_date <= b.diagnosisdate
	where index_date ^= . and prxmatch('/^(305.5|F11.1|304.0|304.7|F11.2)/', upcase(dx))
	group by a.id;

	create table incl_dx_oud as
	select distinct a.id, incl_dx_oud, index_dx_date, encountertype as index_encounter
	from incl_dx_oud_prep as a
	left join visit_type as b
	on a.id = b.id and diagnosisdate = index_dx_date
	order by id, encountertype;

	create table dx_2nd_oud as
	select distinct a.id, 1 as dx_2nd_oud, min(diagnosisdate) as index_dx_2nd format=date9.
	from cohort_step1 as a
	inner join diagnoses as b
	on a.id = b.id and a.index_date <= b.diagnosisdate
	where index_date ^= . and prxmatch('/^(305.5|F11.1|304.0|304.7|F11.2)/', upcase(dx)) and '01jan2019'd <= b.diagnosisdate
	group by a.id;
quit;

proc sort data=incl_dx_oud nodupkey;
	by id;
run;

data cohort_step2;
	merge cohort_step1
		incl_dx_oud;
	by id;
run;

*At least one visit for mental health or substance use in the past year;
proc sql noprint;
	create table base_svc_psych as
	select distinct a.id, 1 as base_svc_psych
	from cohort_step2 as a
	inner join visits as b
	on a.id = b.id and index_dx_date - 365 <= encounterdate < index_dx_date
	where strip(propcase(apptstatus)) = 'Arrived' and encountertype in ('Mental Health', 'Substance abuse');
quit;

*Prep med table;
data ost;
	set meds;
	if (find(medicationname, "BUPRENORPHINE") > 0 and lowcase(route) in ("oral", "sublingual", "film")) or
		medicationname = "BUPRENORPHINE HCL-NALOXONE 8-2 SUBL" then bup = 1;
	if medicationname = "BUPRENORPHINE" and lowcase(route) = "subcutaneous" then injbup = 1;
	if find(medicationname, "METHADONE") > 0 and lowcase(route) in ("oral", "unspecified") and form ^= 'Tablet' then methadone = 1;
	if medicationname = "NALTREXONE" then naltr = 1;
	if bup = 1 or injbup = 1 or methadone = 1 or naltr = 1 then output;	/* Those who initiate naltrexone may do so for other indications */
run;

*Get earliest buprenorphine start date after OUD diagnosis;
*There are people who initiate buprenorphine on the same day as the diagnosis;
*There are people who initiate buprenorphine on the same day and never receive buprenorphine again;
*There are people who initiate buprenorphine on the same day and a later day;
proc sql noprint;
	create table fu_med_bup as
	select distinct a.id, 1 as fu_med_bup, min(b.startdate) as bup_st_date format=date9.
	from cohort_step2 as a
	inner join ost as b
	on a.id = b.id and index_dx_date < startdate
	where bup = 1 or injbup = 1 and index_dx_date ^= .
	group by a.id;
quit;

*Get earliest methadone start date after OUD diagnosis;
proc sql noprint;
	create table fu_med_mthd as
	select distinct a.id, 1 as fu_med_mthd, min(b.startdate) as mthd_st_date format=date9.
	from cohort_step2 as a
	inner join ost as b
	on a.id = b.id and index_dx_date < startdate
	where methadone = 1 and index_dx_date ^= .
	group by a.id;
quit;

*Baseline mental health-related diagnoses assessed at and up to one year prior to index OUD diagnosis;
proc sql noprint;
	/* Prevalent OUD diagnosis */
	create table prev_dx_oud as
	select distinct a.id, 1 as prev_dx_oud
	from cohort_step2 as a
	inner join diagnoses as b
	on a.id = b.id and index_dx_date - 365 <= diagnosisdate < index_dx_date
	where prxmatch('/^(305.5|F11.1|304.0|304.7|F11.2)/', upcase(dx))
	order by a.id;

	/* Depression diagnosis */
	create table base_dx_depr as
	select distinct a.id, 1 as base_dx_depr
	from cohort_step2 as a
	inner join diagnoses as b
	on a.id = b.id and diagnosisdate between index_dx_date - 365 and index_dx_date
	where prxmatch('/^(296.2|296.3|Major|F32.0|F32.1|F32.2|F32.3|F32.9|F33.0|F33.1|F33.2|F33.3|F33.8|F33.9|Depression|311)/', upcase(dx))
	order by a.id;

	/* Anxiety diagnosis */
	create table base_dx_anxi as
	select distinct a.id, 1 as base_dx_anxi
	from cohort_step2 as a
	inner join diagnoses as b
	on a.id = b.id and diagnosisdate between index_dx_date - 365 and index_dx_date
	where prxmatch('/^(300.00|300.02|Anxiet|F41.1|F41.9)/', upcase(dx))
	order by a.id;

	/* Bipolar disorder diagnosis */
	create table base_dx_bipo as
	select distinct a.id, 1 as base_dx_bipo
	from cohort_step2 as a
	inner join diagnoses as b
	on a.id = b.id and diagnosisdate between index_dx_date - 365 and index_dx_date
	where prxmatch('/^(296.0|296.1|296.4|296.5|296.6|296.7|296.80|296.89|F31.)/', upcase(dx))
	order by a.id;

	/* Schizophrenia diagnosis */
	create table base_dx_schi as
	select distinct a.id, 1 as base_dx_schi
	from cohort_step2 as a
	inner join diagnoses as b
	on a.id = b.id and diagnosisdate between index_dx_date - 365 and index_dx_date
	where prxmatch('/^(Schizoph|295|F20)/', upcase(dx))
	order by a.id;

	/* PTSD diagnosis */
	create table base_dx_ptsd as
	select distinct a.id, 1 as base_dx_ptsd
	from cohort_step2 as a
	inner join diagnoses as b
	on a.id = b.id and diagnosisdate between index_dx_date - 365 and index_dx_date
	where prxmatch('/^(309.81|F43.12|F43.10)/', upcase(dx))
	order by a.id;

	/* Alcohol use disorder diagnosis */
	create table base_dx_aud as
	select distinct a.id, 1 as base_dx_aud
	from cohort_step2 as a
	inner join diagnoses as b
	on a.id = b.id and diagnosisdate between index_dx_date - 365 and index_dx_date
	where prxmatch('/^(305.0|F10.1|F10.2|V11.3|303)/', upcase(dx))
	order by a.id;

	/* Cocaine use disorder */
	create table base_dx_cud as
	select distinct a.id, 1 as base_dx_cud
	from cohort_step2 as a
	inner join diagnoses as b
	on a.id = b.id and diagnosisdate between index_dx_date - 365 and index_dx_date
	where prxmatch('/^(305.6|F14.1|304.2|F14.2)/', upcase(dx))
	order by a.id;
quit;

*Baseline self-reported opioid use, cocaine use, marijuana use assessed at and up to one year prior to index OUD diagnosis;
*Allows for missing data;
proc sql noprint;
	/* Opioids */
	create table base_int_oud as
	select distinct a.id, max(herint) as base_int_oud
	from cohort_step2 as a
	inner join interviews1 as b
	on a.id = b.id and prodt between index_dx_date - 365 and index_dx_date
	group by a.id;

	/* Cocaine */
	create table base_int_cud as
	select distinct a.id, max(cocint) as base_int_cud
	from cohort_step2 as a
	inner join interviews1 as b
	on a.id = b.id and prodt between index_dx_date - 365 and index_dx_date
	group by a.id;

	/* Marijuana */
	create table base_int_mud as
	select distinct a.id, max(marijint) as base_int_mud
	from cohort_step2 as a
	inner join interviews1 as b
	on a.id = b.id and prodt between index_dx_date - 365 and index_dx_date
	group by a.id;

	/* Hazardous alcohol */
	create table base_int_hazalc as
	select distinct a.id, max(hazalcint) as base_int_hazalc
	from cohort_step2 as a
	inner join interviews1 as b
	on a.id = b.id and prodt between index_dx_date - 365 and index_dx_date
	group by a.id;
quit;

*Get substance reviews data to supplement interview data;
proc sql noprint;
	create table base_rev_coc as
	select distinct a.id, max(b.cocrev) as base_rev_coc
	from cohort_step2 as a
	inner join substance as b
	on a.id = b.id and ((revenddt between index_dx_date - 365 and index_dx_date) or (revstartdt between index_dx_date - 365 and index_dx_date))
	group by a.id;

	create table base_rev_her as
	select distinct a.id, max(b.herrev) as base_rev_her
	from cohort_step2 as a
	inner join substance as b
	on a.id = b.id and ((revenddt between index_dx_date - 365 and index_dx_date) or (revstartdt between index_dx_date - 365 and index_dx_date))
	group by a.id;

	create table base_rev_hazalc as
	select distinct a.id, max(b.hazalcrev) as base_rev_hazalc
	from cohort_step2 as a
	inner join substance as b
	on a.id = b.id and ((revenddt between index_dx_date - 365 and index_dx_date) or (revstartdt between index_dx_date - 365 and index_dx_date))
	group by a.id;
quit;

*Opioid use during follow-up, earliest instance of 1-year free of opioid use;
proc sql noprint;
	create table fu_rev_her_1 as
	select distinct a.id, a.index_dx_date, revenddt as date, herrev as fu_oud
	from cohort_step2 as a
	inner join substance as b
	on a.id = b.id and revenddt > index_dx_date
	where herrev = 1 and index_dx_date ^= .
	order by a.id, revenddt;

	create table fu_int_her_1 as
	select distinct a.id, a.index_dx_date, prodt as date, herint as fu_oud
	from cohort_step2 as a
	inner join interviews1 as b
	on a.id = b.id and prodt > index_dx_date
	where herint = 1 and index_dx_date ^= .
	order by a.id, prodt;

	create table fu_her_1 as
	select *
	from fu_rev_her_1
	union
	select *
	from fu_int_her_1
	order by id, date;
quit;

data fu_her_2;
	set fu_her_1;
	by id;
	format quit_her_date date9.;
	day_diff = date - lag(date);
	if first.id then day_diff = date - index_dx_date;
	quit_her_date = lag(date) + 365;
	if first.id then quit_her_date = index_dx_date + 365;
	spice = quit_her_date - index_dx_date;
	if day_diff > 365 then do;
		fu_quit_her = 1;
		output;
	end;
	keep id fu_quit_her quit_her_date;
run;

proc sort data=fu_her_2 out=fu_quit_her nodupkey;
	by id;
run;

/* Baseline buprenorphine or methadone use */
*Look for ACTIVE buprenorphine--index between start and stop date;
*History of buprenorphine use;
*Methadone has self-reported start/stop dates;
/*proc sql noprint;*/
	/* Buprenorphine */
/*	create table base_med_bup as*/
/*	select distinct a.id, 1 as base_med_bup*/
/*	from cohort_step2 as a*/
/*	inner join ost as b*/
/*	on a.id = b.id and startdate between index_dx_date - 365 and index_dx_date*/
/*	where bup = 1 or injbup = 1*/
/*	order by a.id;*/

	/* Methadone */
/*	create table base_med_mthd as*/
/*	select distinct a.id, 1 as base_med_mthd*/
/*	from cohort_step2 as a*/
/*	inner join ost as b*/
/*	on a.id = b.id and startdate between index_dx_date - 365 and index_dx_date*/
/*	where methadone = 1*/
/*	order by a.id;*/
/*quit;*/
/* History of buprenorphine or methadone use */
proc sql noprint;
	/* Buprenorphine */
	create table base_med_bup as
	select distinct a.id, 1 as base_med_bup
	from cohort_step2 as a
	inner join ost as b
	on a.id = b.id and startdate <= index_dx_date
	where bup = 1 or injbup = 1
	order by a.id;

	/* Methadone */
	create table base_med_mthd as
	select distinct a.id, 1 as base_med_mthd
	from cohort_step2 as a
	inner join ost as b
	on a.id = b.id and startdate <= index_dx_date
	where methadone = 1
	order by a.id;
quit;

/* Actively using buprenorphine or methadone */
proc sql noprint;
	/* Buprenorphine */
	create table active_med_bup as
	select distinct a.id, 1 as active_med_bup
	from cohort_step2 as a
	inner join ost as b
	on a.id = b.id and index_dx_date between startdate and stopdate
	where bup = 1 or injbup = 1
	order by a.id;

	/* Methadone */
	create table active_med_mthd as
	select distinct a.id, 1 as active_med_mthd
	from cohort_step2 as a
	inner join ost as b
	on a.id = b.id and index_dx_date between startdate and stopdate
	where methadone = 1
	order by a.id;
quit;

/* Baseline healthcare service utilization */
proc sql;
	create table svc_use as
	select distinct a.id,
		sum(case when apptstatus = 'Arrived' then 1 else 0 end) as svc_use_arrived,
		sum(case when apptstatus = 'No show' then 1 else 0 end) as svc_use_noshow,
		calculated svc_use_arrived + calculated svc_use_noshow as svc_use,
/*		case when calculated svc_use > 0 then 1 else 0 end as base_svc_use,*/
		calculated svc_use as base_svc_appt,
		calculated svc_use_arrived / calculated svc_use as base_svc_prop
	from cohort_step2 as a
	inner join visits as b
	on a.id = b.id and encounterdate between index_dx_date - 365 and index_dx_date /* 1 year prior, inclusive */
	where encountertype in ('HIV primary care', 'Initial') /* Only primary care visits for HIV */
		and apptstatus in ('Arrived', 'No show') /* Excluding cancelled visits */
	group by a.id;
quit;

/* Get patients loss to clinic */
proc sql noprint;
	create table loss_to_clinic_prep1 as
	select distinct a.*, b.encounterdate
	from cohort_step2 as a
	inner join visits as b
	on a.id = b.id and encounterdate >= index_dx_date
	where apptstatus = 'Arrived' and encountertype in ('HIV primary care', 'Initial') and index_dx_date ^= .
	order by a.id, b.encounterdate;
quit;

data fu_loss_clinic;
	set loss_to_clinic_prep1;
	by id;
	retain ever_loss;
	format prev_visit_date mmddyy10.;
	prev_visit_date = lag(encounterdate);
	if first.id then do;
		prev_visit_date = .;
		ever_loss = 0;
	end;
	if nmiss(encounterdate, prev_visit_date) = 0 then days_btwn_visits = encounterdate - prev_visit_date;
	if days_btwn_visits > 365 then fu_loss_clinic = 1;
	else fu_loss_clinic = 0;
	ever_loss + fu_loss_clinic;
	if ever_loss = 1 and fu_loss_clinic = 1;
	rename prev_visit_date = loss_fu_date;
	keep id prev_visit_date fu_loss_clinic;
run;

/* Social determinants of health */
proc sql;
	create table sdoh_2nd_prep as
	select distinct a.id, contact_date, HOUSING_STATUS, INCARC_IN_LAST_YR, fpl
	from cohort_step2 as a
	inner join sdoh as b
	on a.id = b.id and index_dx_date >= contact_date > index_dx_date - 365
	order by a.id, b.contact_date;
quit;

*Get most recent result;
data sdoh_2nd;
	set sdoh_2nd_prep;
	by id;

	if not missing(fpl) and fpl < 100 then below_fpl = 1;
	else if missing(fpl) then call missing (below_fpl);
	else below_fpl = 0;

/*	Pulled from the SDoH codebook*/
/*	1=Housed Institution; 2=Non-permanently; 3=Permanently housed; 4=Other*/
	if housing_status in (1, 3) then perm_house = 1;
	else if missing(housing_status) then call missing(perm_house);
	else perm_house = 0;

	if incarc_in_last_yr = 1 then incarc = 1;
	else if missing(incarc_in_last_yr) then incarc = .;
	else incarc = 0;

	if last.id;
	drop fpl housing_status incarc_in_last_yr;
run;

data cohort_step3;
	merge cohort_step2
		incl_dx_oud
		base_dx_depr
		base_dx_anxi
		base_dx_bipo
		base_dx_schi
		base_dx_ptsd
		base_dx_aud
		base_dx_cud
		base_rev_her
		base_int_oud
		base_rev_hazalc
		base_int_hazalc
		base_rev_coc
		base_int_cud
		base_int_mud
		base_med_bup
		base_med_mthd
		active_med_bup
		active_med_mthd
		svc_use
		base_svc_psych
		fu_med_bup
		fu_med_mthd
		fu_loss_clinic
		fu_quit_her
		prev_dx_oud
		dx_2nd_oud
		sdoh_2nd
		;
	by id;

	*Reformat variables;
	format birthsex race $ 10. end_date date9.;
	if birthmale = 1 then birthsex = 'Male';
	else birthsex = 'Female';
	if raceeth = 2 then race = 'Black';
	else race = 'Non-Black';
	if index_date ^= . then index_year = year(index_date);
	array a{*} incl_: fu_: base_dx_: base_med_: prev_: base_active_: /*base_svc_use*/ active_med_: base_svc_psych;
	do i = 1 to dim(a);
		if a{i} = . then a{i} = 0;
	end;

	*Bipolar takes priority over depression;
	if base_dx_bipo = 1 then base_dx_depr = 0; 

	*Get event;
	if index_dx_date ^= . then do;
		end_date = min('31dec2024'd, bup_st_date, mthd_st_date, dod, loss_fu_date, quit_her_date); /* Get the earliest event */

		if end_date = '31dec2024'd then event = 0; /* Censor */
		else if end_date = bup_st_date and bup_st_date ^= . then event = 1; /* Buprenorphine */
		else if end_date = mthd_st_date and mthd_st_date ^= . then event = 2; /* Methadone */
		else if end_date = quit_her_date and quit_her_date ^= . then event = 3; /* Quit opioids for a year */
		else if end_date = loss_fu_date and loss_fu_date ^= . then event = 4; /* Loss to clinic */
		else if end_date = dod and dod ^= . then event = 5; /* Death */

		if end_date ^= . then time = end_date - index_dx_date;

		*Administrative censoring at 5 years from the start of follow-up;
		if time > 1827 then time = 1827;
	end;
	drop i;

	*Combine cocaine use from interview and cocaine use from substance review, and do same with heroin;
	base_int_oud = max(of base_int_oud, base_rev_her);
	base_int_hazalc = max(of base_int_hazalc, base_rev_hazalc);
	base_int_cud = max(of base_int_cud, base_rev_coc);
/*	if base_int_oud = 1 or base_rev_her = 1 then base_int_oud = 1;*/
/*	if base_int_hazalc = 1 or base_rev_hazalc = 1 then base_int_hazalc = 1;*/
/*	if base_int_cud = 1 or base_rev_coc = 1 then base_int_cud = 1;*/

	*Get primary cohorts;
	if sum(of incl_:) = 2 then analytic_cohort = 1;
/*	if analytic_cohort = 1 and sum(of base_active_:) = 0 then survival_cohort = 1;*/
	if analytic_cohort = 1 and active_med_bup = 0 and base_int_oud = 1 then survival_cohort = 1;
	else survival_cohort = 0;

	*Get secondary analysis cohort;
	if nmiss(end_date, index_dx_2nd) = 0 and end_date <= index_dx_2nd then call missing(dx_2nd_oud, index_dx_2nd);

	if survival_cohort = 1 and dx_2nd_oud = 1 then do;
		survival_cohort_2nd = 1;
		time_2nd = end_date - index_dx_2nd;
	end;
	else survival_cohort_2nd = 0;

	*Get baseline groups of active buprenorphine users, active methadone users, and those on no treatment;
	if active_med_bup = 1 then group = 'Buprenorphine';
	else if active_med_mthd = 1 then group = 'Methadone';
	else group = 'No treatment';

	*Fix capitalizations in index encounter;
	index_encounter = compbl(lowcase(index_encounter));
	if substr(index_encounter, 1, 3) = 'hiv' then substr(index_encounter, 1, 3) = 'HIV';
	substr(index_encounter, 1, 1) = upcase(substr(index_encounter, 1, 1));

	*Index encounter to only include substance use or mental health;
	if index_encounter in ('Mental health', 'Substance abuse') then index_su_mh = 1;
/*	else if missing(index_encounter) then call missing(index_su_mh);*/
	else index_su_mh = 0;

	*Indicator for index date after 2019;
	if index_year >= 2019 then year_2019 = 1; else year_2019 = 0;

	*SDoH;

	drop svc_use base_rev_coc base_rev_her base_rev_hazalc index_encounter;
run;

proc export data=cohort_step3
	file="&path/cohort.xlsx"
	dbms=xlsx
	replace;
run;

*Variable 1 = bup, 2 = death, 3 = methadone, 0 = follow-up;
/*proc phreg data=cohort_step3 noprint; */
/*	model time * event(0) = / eventcode=1; *this is the empty model; */
/*/*	strata type; *assuming type is the name of your exposure variable; */*/
/*	baseline out=cif cif=r / method=pl; *the data set "km" will contain your survival estimates;*/
/*/*	weight _ATE_; *if you want adjusted curves;*/*/
/*run;*/
/**/
/*proc sgplot data=cif;*/
/*	series x=time y=r;*/
/*run;*/

*herint, cocint, marijint within interviews,
*Leaving out amphetamines due to low prevalence of amphetamine use in Baltimore population, specifically in JHHCC (~ 1%)