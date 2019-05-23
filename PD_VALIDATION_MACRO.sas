filename mycat catalog "work.mdlInfo";
%include mycat (mi0);

%include "/u01/sas/ADWH/code/VALIDATION_MACROS.sas";

%let modelId = &_MM_ModelLabel;

data TECH_VALIDATION_REPORTS;
	set VDM_CS.TECH_VALIDATION_REPORTS;
run;

proc sql noprint;
	select root_model_id, Datasetname, model_description, client_id, Actual_Var, Output_Var, Score_Var, Segment_Var, Scale_Var,
		Input_Var_List, Input_Var_List_gr, period_var, period_label_var
	into :rootModelId, :DataSetName, :modelDesc, :keyVar, :actualVar, :outputVar, :scoreVar, :segmentVar, :scaleVar,
		:inputVarList, :inputVarList_gr, :periodVar, :periodLabelVar
	from TECH_VALIDATION_REPORTS where model_id = "&modelId.";
quit;

data inputdataset;
set VDM_CS.&DataSetName.;
run;

data factor_bin_label (keep= factor_gr bin_number factor_gr_label);
	set VDM_CS.MREF_IRB_FACTOR_BIN;
	where model_id = "&rootModelId.";
	factor_gr_label = put(SCORE,BEST9.5)||" "||BIN_VALUE;
run;

%global factorBinLabel;
%let factorBinLabel = factor_bin_label;

proc sql noprint;
	select count(*)
	into :isBinLabel
	from factor_bin_label;
quit;

%macro is_bin_label();
	%if "&isBinLabel." = "0" %then %do;
		%let factorBinLabel = 0;
	%end;
%mend is_bin_label;

%is_bin_label();

data factor_label;
	set VDM_CS.MREF_IRB_FACTOR_LABEL;
run;

data threshold_set;
	set VDM_CS.MREF_IRB_VAL_MACRO_THRESHOLD;
run;