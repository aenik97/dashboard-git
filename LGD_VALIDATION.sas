
filename mmreport catalog "sashelp.modelmgr.reportexportmacros.source";
%include mmreport;

%MM_ExportReportsBegin(filename=LGD_VALIDATION);

%m_create_LGD_validation_report(
			rawDataSet=inputdataset,
			modelDesc=&modelDesc.,
			outputVar=&outputVar.,
			actualVarLGD=&actualVarLGD.,
			actualVarEAD=&actualVarEAD.,
			inputVarList=&inputVarList.,
			inputVarList_gr=&inputVarList_gr.,
			subModelVar=&SubmodelOutputVar.,
			periodVar=&periodVar.,
			periodLabelVar=&periodLabelVar.,
			factorBinLabelSet=factor_bin_label,
			factorLabelSet=factor_label,
			thresholdSet=threshold_set
);		

%MM_ExportReportsEnd;