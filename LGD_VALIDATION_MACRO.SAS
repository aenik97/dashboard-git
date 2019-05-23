filename mycat catalog "work.mdlInfo";
%include mycat (mi0);

%include "/u01/sas/ADWH/code/VALIDATION_MACROS.sas";

%let modelId = &_MM_ModelLabel;

data TECH_VALIDATION_REPORTS;
	set VDM_CS.TECH_VALIDATION_REPORTS;
run;

proc sql;
	select Datasetname, model_description, Actual_Var, Output_Var, Submodel_output_var,
		Input_Var_List, Input_Var_List_gr, period_var, period_label_var
	into :DataSetName, :modelDesc, :actualVar, :outputVar, :submodelOutputVar,
		:inputVarList, :inputVarList_gr, :periodVar, :periodLabelVar
	from TECH_VALIDATION_REPORTS where model_id = "&modelId.";
quit;

%let actualVarLGD = %SCAN(%str(&actualVar.),1,'|');

%let actualVarEAD = %SCAN(%str(&actualVar.),2,'|');

data inputdataset;
	set VDM_CS.&DataSetName.;
run;

data factor_bin_label (keep= factor_gr bin_number factor_gr_label);
	set VDM_CS.MREF_IRB_FACTOR_BIN;
	where model_id = "&modelId.";
	if SCORE = . then factor_gr_label = BIN_VALUE;
	else factor_gr_label = put(SCORE,BEST9.5)||" "||BIN_VALUE;
run;

data factor_label;
	set VDM_CS.MREF_IRB_FACTOR_LABEL;
run;

data threshold_set;
	set VDM_CS.MREF_IRB_VAL_MACRO_THRESHOLD;
run;