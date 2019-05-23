filename mmreport catalog "sashelp.modelmgr.reportexportmacros.source";
%include mmreport;

%MM_ExportReportsBegin(filename=PD_VALIDATION);

%m_create_PD_validation_report(
			rawDataSet=inputdataset,
			modelDesc=&modelDesc.,
			keyVar=&keyVar.,
			actualVar=&actualVar.,
			outputVar=&outputVar.,
			scoreVar=&scoreVar.,
			segmentVar=&segmentVar.,
			scaleVar=&scaleVar.,
			inputVarList=&inputVarList.,
			inputVarList_gr=&inputVarList_gr.,
			periodVar=&periodVar.,
			periodLabelVar=&periodLabelVar.,
			factorBinLabelSet=&factorBinLabel.,
			factorLabelSet=factor_label,
			thresholdSet = threshold_set
);

%MM_ExportReportsEnd;
