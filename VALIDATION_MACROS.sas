%macro m_information_table(rawDataSet=, actualVar=, periodVar=, periodLabelVar=);
	/* 
		Назначение: Вывод информации о количестве наблюдений и дефолтов в разрезе периодов.
	   
		Параметры:  rawDataSet     - Имя входного набора данных.
					actualVar	   - Имя бинарной фактической переменной.
					periodVar	   - Имя переменной, определяющей период.
					periodLabelVar - Имя переменной, определяющей текстовую метку периода.
	*/

	proc sql;
		create table REPORT_SET as
		select &periodLabelVar.,
			&periodVar.,
			count(*) as observations_count,
			sum(&actualVar.) as default_count,
			(calculated default_count / calculated observations_count) as default_rate format percentn7.2
		from &rawDataSet.
		group by &periodLabelVar., &periodVar.
		order by &periodVar.;
	quit;
		
	proc print data=REPORT_SET noobs label;
		var &periodLabelVar. observations_count default_count default_rate;
		label   &periodLabelVar.="Период"
				observations_count="Число наблюдений"
				default_count="Число договоров в дефолте"
				default_rate="Процент договоров в дефолте"; 
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete REPORT_SET;
	run;

%mend m_information_table;


%macro m_factor_information_table(rawDataSet=, inputVarList=, periodVar=, periodLabelVar=, factorLabelSet=0);
	/* 
		Назначение: Для каждой переменной из inputVarList рассчитывается минимальное, максимальное значения, 
					а также число выбросов в разрезе периода.
	   
		Параметры:  rawDataSet       - Имя входного набора данных.
				    inputVarList     - Строка, содержащая перечень имен переменных, разделитель - '|'.
									   Пример: variable1|variable2|variable3.
					periodVar        - Имя переменной, определяющей период.
					periodLabelVar   - Имя переменной, определяющей текстовую метку периода.				  
					factorLabelSet	 - Набор данных, содержащий лейблы для факторов.
									   Должен содержать следующий набор полей:
											factor character			 - название фактора,
											factor_label character		 - лейбл фактор,
											special_value_list character - перечень специальных значений через запятую.
									   Значение по умолчанию = 0, в этом случае лейблы и специальные значения не используются.
	*/
	
	*** Определение количества входных переменных;
	%let inputVarCnt=%SYSFUNC(countw(&inputVarList.,%STR('|')));
	
	*** Определение периодов и текстовой метки периодов;
	proc sql noprint;
		create table PERIOD_LABEL as
		select distinct &periodVar., &periodLabelVar.
		from &rawDataSet.
		order by &periodVar.;
		
		select count(*)
		into :periodCnt
		from PERIOD_LABEL;
	quit;
	
	%let periodCnt = &periodCnt.;
		
	proc sql noprint;	
		select &periodVar., &periodLabelVar.
		into :period1-:period&periodCnt., :periodLabel1-:periodLabel&periodCnt.
		from PERIOD_LABEL;
	quit;
	
	*** Создание итоговой таблицы;
	proc sql noprint;
		create table REPORT_SET 
		(
			factor character(50),
			period integer,
			min_value float format best18.5,
			max_value float format best18.5,
			count_special float format best18.5,
			special_pct float format percentn7.2
		);
	quit;
	
	*** Цикл по входным переменным;
	%do varIdx=1 %to &inputVarCnt.;
		%let inputVar=%SCAN(%STR(&inputVarList.),&varIdx.,'|');
		
		*** Попытка выбрать список специальных значений, если указан набор с лейблами и специальными значениями;
		%if "&factorLabelSet." = "0" %then %do;
			%let specValueList = spec_val_null;
		%end;
		%else %do;
			*** Выбор списка специальных значений, если список пустой, то в качестве нулевого значения используется строка "spec_val_null";
			proc sql noprint;
				select coalesce(special_value_list, "spec_val_null")
				into :specValueList
				from &factorLabelSet.
				where upcase(factor) = upcase("&inputVar.");
			quit;
		%end;
		
		%let specValueList = &specValueList.;
		
		%if "&specValueList." ^= "spec_val_null" %then %do;
		
			*** Подсчет специальных значений и миссингов в разрезе периода;
			proc sql noprint;
				create table SPECIAL_VALUE_CNT as
				select &periodVar.,
						sum(case when &inputVar. in (&specValueList.) or &inputVar. is missing then 1 else 0 end) as count_special,
						count(*) as counta
				from &rawDataSet.
				group by &periodVar.;
			quit;
			
			*** Удаление специальных значений и миссингов;
			data INPUT_NO_SPEC (keep=&inputVar. &periodVar.);
				set &rawDataSet.;
				where &inputVar. not in (&specValueList.) and &inputVar. ^= .;
			run;
		%end;
		%else %do;
		
			*** Подсчет миссингов в разрезе периода;
			proc sql noprint;
				create table SPECIAL_VALUE_CNT as
				select &periodVar.,
						sum(case when &inputVar. is missing then 1 else 0 end) as count_special,
						count(*) as counta
				from &rawDataSet.
				group by &periodVar.;
			quit;
			
			*** Удаление миссингов;
			data INPUT_NO_SPEC (keep=&inputVar. &periodVar.);
				set &rawDataSet.;
				where &inputVar. ^= .;
			run;
		%end;
		
		*** Таблица с минимумом и максимумом в разрезе периода;
		proc sql noprint;
			create table SCECIAL_VALUE_MIN_MAX as
			select &periodVar.,
				min(&inputVar.) as min_value,
				max(&inputVar.) as max_value
			from INPUT_NO_SPEC
			group by &periodVar.;
		quit;
		
		proc sql noprint;
			insert into REPORT_SET (factor, period, min_value, max_value, count_special, special_pct)
			select "&inputVar." as factor,
					a.&periodVar. as period,
					b.min_value,
					b.max_value,
					a.count_special,
					a.count_special / a.counta as special_pct
			from SPECIAL_VALUE_CNT as a
			left join SCECIAL_VALUE_MIN_MAX as b
				on a.&periodVar. = b.&periodVar.;
		quit;
		
		*** Удаление лишних наборов данных;
		proc datasets nolist;
			delete SCECIAL_VALUE_MIN_MAX SPECIAL_VALUE_CNT;
		run;
	%end;
	
	*** Если таблица лейблов указана, то осуществляется создание и вывод таблицы с лейблами факторов;
	%if "&factorLabelSet." ^= "0" %then %do;
		proc sql noprint;
			create table REPORT_FACTOR_LABEL as
			select distinct a.factor,
					trim(b.factor_label) as factor_label
			from REPORT_SET as a
			left join &factorLabelSet. as b
				on upcase(a.factor) = upcase(b.factor);
		quit;
		
		Title2 h=12pt "Список и наименование факторов";
		
		proc report data=REPORT_FACTOR_LABEL SPLIT='';
			column factor factor_label;
			define factor / display "Фактор"
							style(column)=[fontsize=1]
							style(header)=[fontsize=1];
			define factor_label /	display "Наименование фактора"
									style(column)=[cellwidth=4in fontsize=1]
									style(header)=[fontsize=1]; 
		run;
		
		Title1;
	%end;
	
	*** Вывод результата в разрезе периода;
	%do periodNum=1 %to &periodCnt.;
		Title2 h=12pt "Период: &&periodLabel&periodNum.";	
		
		proc report data=REPORT_SET(where=(period = &&period&periodNum.)) SPLIT='';
			column factor min_value max_value count_special special_pct;
			define factor / display "Фактор";
			define min_value / display "Фактическое минимальное значение";
			define max_value / display "Фактическое максимальное значение";
			define count_special / display "Общее число специальных значений";
			define special_pct / display "Специальные значения, %";
		run;
		
		Title1;
	%end;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete REPORT_SET REPORT_SET_LABEL INPUT_NO_SPEC PERIOD_LABEL REPORT_FACTOR_LABEL;
	run;
	
%mend m_factor_information_table;


%macro m_factor_distribution(rawValDataSet=, rawDevDataSet=, inputVarList=, factorLabelSet=0);
	/* 
		Назначение: Для каждой переменной из inputVarList строится гистограмма распределения
				    для входных наборов данных.
	   
		Параметры:  rawValDataSet    - Имя выборки для валидации.
					rawDevDataSet    - Имя выборки для разработки.
				    inputVarList     - Строка, содержащая перечень имен переменных, разделитель - '|'.
									   Пример: variable1|variable2|variable3.
					factorLabelSet	 - Набор данных, содержащий лейблы для факторов.
									   Должен содержать следующий набор полей:
											factor character			 - название фактора,
											factor_label character		 - лейбл фактора,
											special_value_list character - перечень специальных значений через запятую,
											outlier_type character		 - тип удаления выбросов ('0' - не удалять, '1' - 3сигма,
																								  '2' - квантиль, '3' - оставить отрезок),
											quantile_value				 - значение квантиля (если outlier_type = 2),
											interval_start				 - начало отрезка (если outlier_type = 3),
											interval_finish				 - конец отрезка (если outlier_type = 3).
									   Значение по умолчанию = 0, в этом случае лейблы и специальные значения не используются.
	*/
	
	*** Определение количества входных переменных;
	%let inputVarCnt=%SYSFUNC(countw(&inputVarList.,%STR('|')));
	
	*** Создание набора для разработки;
	data INPUT_SET_1;
		set &rawDevDataSet.(keep=
							%do varIdx=1 %to &InputVarCnt.;
								%SCAN(%STR(&inputVarList.),&varIdx.,'|')
							%end;
							);
	run;
	
	*** Создание набора для валидации;
	data INPUT_SET_2;
		set &rawValDataSet.(keep=
							%do varIdx=1 %to &InputVarCnt.;
								%SCAN(%STR(&inputVarList.),&varIdx.,'|')
							%end;
							);
	run;
	
	%if "&factorLabelSet." ^= "0" %then %do;
		proc sql noprint;
			create table FACTOR_LABEL_SET as
			select *
			from &factorLabelSet.
			where upcase(factor) in (%do varIdx=1 %to &InputVarCnt.;
										"%UPCASE(%SCAN(%STR(&inputVarList.), &varIdx.,'|'))"
										%if &varIdx. < &InputVarCnt. %then
											,
										;
									 %end;)
			;
			
			select distinct outlier_type
			into :outlierTypeList separated by ' '
			from FACTOR_LABEL_SET
			order by outlier_type;
		quit;
		
		%let outlierTypeCnt=%SYSFUNC(countw(&outlierTypeList.));
		
		%do idx = 1 %to &outlierTypeCnt.;
			%let outlierType=%SCAN(%STR(&outlierTypeList.),&idx.);
			
			proc sql noprint;
				select factor
				into :factorListType_&outlierType. separated by ' '
				from FACTOR_LABEL_SET
				where outlier_type = "&outlierType.";
			quit;
		%end;
		
		*** Цикл по входным наборам данных, расчет необходимых статистик;
		%do setIdx=1 %to 2;
		
			proc sql noprint;
				create table FACTOR_BORDER_&setIdx.
				(
					factor character(50),
					border_min float format 18.5,
					border_max float format 18.5
				);
			quit;
			
			proc sql noprint;
				select count(*)
				into :countType1
				from FACTOR_LABEL_SET
				where outlier_type = '1';
			quit;
			
			%if &countType1. > 0 %then %do;
		
				ods exclude all;
				
				proc univariate data=INPUT_SET_&setIdx.;
					var &factorListType_1.;
					ods output Moments=MOMENTS;
				run;
				
				ods exclude none;
				
				data MOMENTS;
					set MOMENTS (keep= VarName Label1 nValue1);
					where Label1 in ("N", "Mean", "Std Deviation");
				run;
				
				proc sort data= MOMENTS;
					by VarName Label1;
				run;
				
				proc transpose data=MOMENTS out=MOMENTS_TRANSPOSED;
					by VarName;
				run;
				
				data MOMENTS_TRANSPOSED;
					set MOMENTS_TRANSPOSED (drop=_NAME_);
					rename COL1 = mean COL2 = N COL3 = std_dev;
				run;
				
				*** Расчет пороговых значений для определения выбросов;
				data THREE_SIGMA_BORDER (keep= factor border_min border_max);
					set MOMENTS_TRANSPOSED;
					format border_min border_max 18.5;
					border_max = 3 * std_dev + mean;
					border_min = -3 * std_dev + mean;
					if border_min > 0 then border_min = 0;
					rename VarName = factor;
				run;
				
				data FACTOR_BORDER_&setIdx.;
					set FACTOR_BORDER_&setIdx. THREE_SIGMA_BORDER;
				run;
			%end;
			
			proc sql noprint;
				select count(*)
				into :countType2
				from FACTOR_LABEL_SET
				where outlier_type = '2';
			quit;
			
			%if &countType2. > 0 %then %do;
			
				%let factorListType_2Cnt=%SYSFUNC(countw(&factorListType_2.));
				
				%do varIdx=1 %to &factorListType_2Cnt.;
					%let currentFactor = %SCAN(%STR(&factorListType_2.),&varIdx.);
				
					proc sql noprint;
						select quantile_value, 100 - quantile_value
						into :quantileValueFin , :quantiveValueStart
						from FACTOR_LABEL_SET
						where upcase(factor) = upcase("&currentFactor.");
					quit;
					
					proc stdize data=INPUT_SET_&setIdx.
						PctlMtd=ord_stat
						outstat=QUANTILE_BORDER
						out=DATA1
						pctlpts= &quantiveValueStart., &quantileValueFin.;
						var &currentFactor.;
					run;
				
					*** Удаление лишних наборов данных;
					proc datasets nolist;
						delete DATA1;
					run;
					
					data QUANTILE_BORDER;
						set QUANTILE_BORDER;
						where _type_ =: 'P';
					run;
					
					proc transpose data=QUANTILE_BORDER
						out=QUANTILE_BORDER;
					run;
					
					data QUANTILE_BORDER;
						set QUANTILE_BORDER(keep= Col1 Col2);
						factor = "&currentFactor.";
						if Col1 > 0 then Col1 = 0;
						rename Col1 = border_min Col2 = border_max;
					run;
					
					data FACTOR_BORDER_&setIdx.;
						set FACTOR_BORDER_&setIdx. QUANTILE_BORDER;
					run;
				%end;
			%end;
			
			proc sql noprint;
				select count(*)
				into :countType3
				from FACTOR_LABEL_SET
				where outlier_type = '3';
			quit;
			
			%if &countType3. > 0 %then %do;
				data INTERVAL_BORDER (keep= factor border_min border_max);
					set FACTOR_LABEL_SET;
					where outlier_type = '3';
					rename interval_start = border_min interval_finish = border_max;
				run;
				
				data FACTOR_BORDER_&setIdx.;
					set FACTOR_BORDER_&setIdx. INTERVAL_BORDER;
				run;
			%end;
		%end;
	%end;
	
	*** Цикл по входным переменным; 
	%do varIdx=1 %to &inputVarCnt.;
		%let inputVar=%SCAN(%STR(&inputVarList.),&varIdx.,'|');
		
		*** Попытка выбрать список специальных значений, если указан набор с лейблами и специальными значениями;
		%if "&factorLabelSet." = "0" %then %do;
			%let specValueList = spec_val_null;
			%let outlierFlg = 0;
		%end;
		%else %do;
		
			*** Определение списка специальных значений, а также флага удаления выбросов;
			proc sql noprint;
				select coalesce(special_value_list, "spec_val_null"), case when outlier_type ^= '0' then '1' else '0' end
				into :specValueList, :outlierFlg
				from FACTOR_LABEL_SET
				where upcase(factor) = upcase("&inputVar.");
			quit;
			
			%let specValueList = &specValueList.;
			%let outlierFlg = &outlierFlg.;
		%end;
		
		*** Цикл по наборам (валидация и разработка);
		%do setIdx=1 %to 2;
		
			*** Удаление специальных значений и миссингов;
			%if "&specValueList." ^= "spec_val_null" %then %do;
				data INPUT_NO_SPEC_&setIdx.;
					set INPUT_SET_&setIdx. (keep=&inputVar.);
					where &inputVar. not in (&specValueList.);
				run;
			%end;
			%else %do;
				data INPUT_NO_SPEC_&setIdx.;
					set INPUT_SET_&setIdx. (keep=&inputVar.);
				run;
			%end;
			
			*** Удаление выбросов;
			%if "&outlierFlg." = "1" %then %do;
				proc sql noprint;
					create table REPORT_SET_&setIdx. as
					select a.&inputVar.
					from INPUT_NO_SPEC_&setIdx. as a
					join FACTOR_BORDER_&setIdx. as b
					on upcase(b.factor) = upcase("&inputVar.")
					where a.&inputVar. >= b.border_min and a.&inputVar. <= b.border_max;
				quit;
			%end;
			%else %do;
				data REPORT_SET_&setIdx.;
					set INPUT_NO_SPEC_&setIdx.;
				run;
			%end;
		%end;
		
		*** Объединение наборов;
		data REPORT_SET;
			set REPORT_SET_1 REPORT_SET_2(rename=(&inputVar.=&inputVar._));
		run;
		
		*** Выбор лейбла фактора;
		%let factorLabel = &inputVar.;
		
		%if "&factorLabelSet." ^= "0" %then %do;
			proc sql noprint;
				select factor_label as factor_label
				into :factorLabel
				from &factorLabelSet.
				where upcase(factor) = upcase("&inputVar.");
			quit;
			
			%let factorLabel = &inputVar.: &factorLabel.;	
		%end;
			
		Title3 "&factorLabel.";
		
		*** Вывод результата;
		proc sgplot data=REPORT_SET;
			histogram &inputVar. / fillattrs=graphdata1
								   transparency=0.1
								   legendlabel="Выборка для валидации"
								   dataskin=MATTE;
							  
			histogram &inputVar._    / fillattrs=graphdata2
									   transparency=0.5
									   legendlabel="Выборка для разработки"
									   dataskin=MATTE;
								   
			xaxis display=(noline noticks nolabel);
			yaxis display=(noline noticks) label="Проценты";
		run;
		
		Title1;
	%end;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete MOMENTS MOMENTS_TRANSPOSED REPORT_SET THREE_SIGMA_BORDER INTERVAL_BORDER QUANTILE_BORDER FACTOR_LABEL_SET
			%do setIdx=1 %to 2;
				INPUT_SET_&setIdx. REPORT_SET_&setIdx. INPUT_NO_SPEC_&setIdx. STATISTICS_BY_INPUTVAR_&setIdx. FACTOR_BORDER_&setIdx.
			%end;
		;
	run;
	
%mend m_factor_distribution;


%macro m_group_factor_distribution(rawValDataSet=, rawDevDataSet=, actualVar=, inputVarList=, factorBinLabelSet=0, factorLabelSet=0, y2label=);
	/* 
		Назначение: Для каждой переменной из inputVarList строится график распределения по группам,
				    а также график уровня дефолта по каждой группе.
	   
		Параметры:  rawValDataSet		- Имя выборки для валидации.
					rawDevDataSet		- Имя выборки для разработки.
				    actualVar			- Имя фактической переменной.
				    inputVarList		- Строка, содержащая перечень имен переменных, разделитель - '|'.
										  Пример: variable1|variable2|variable3.
					factorBinLabelSet	- Набор данных, содержащий лейблы для значений бинов.
										  Должен содержать следующий набор полей:
											factor_gr character			- название фактора,
											bin_number integer			- номер бина,
											factor_gr_label character	- лейбл бина.
										  Значение по умолчанию = 0, в этом случае лейблы не используются.
					factorLabelSet	 	- Набор данных, содержащий лейблы для факторов.
									      Должен содержать следующий набор полей:
											factor character			- название фактора,
											factor_label character		- лейбл фактора.
										  Значение по умолчанию = 0, в этом случае лейблы не используются.
					y2label				- Лейбл оси y2.
	*/
	   
	*** Определение количества входных переменных;
	%let inputVarCnt=%SYSFUNC(countw(&inputVarList.,%STR('|')));
	
	*** Определение количества строк во входных наборах;
	proc sql noprint;
		select count(*) as cnt
		into :countDev
		from &rawDevDataSet.;
		
		select count(*) as cnt
		into :countVal
		from &rawValDataSet.;
	quit;
	
	*** Цикл по каждой переменной;
	%do varIdx=1 %to &inputVarCnt.;
		%let inputVar=%SCAN(%STR(&inputVarList.),&varIdx.,'|');
			
		proc sql noprint;
		
			*** Для каждого значения переменной определяется процент и среднее значение фактической переменной;
			create table DEVELOPMENT_SET as
			select &inputVar.,
					count(*) / &countDev. as pct,
					avg(&actualVar.) as avg_fact
			from &rawDevDataSet.
			group by &inputVar.;
			
			create table VALIDATION_SET as
			select &inputVar.,
					count(*) / &countVal. as pct,
					avg(&actualVar.) as avg_fact
			from &rawValDataSet.
			group by &inputVar.;
			
			*** Создается итоговый набор для построения отчета;
			create table REPORT_SET as
			select coalesce(a.&inputVar., b.&inputVar.) as &inputVar.,
					coalesce(put(a.&inputVar.,8.), put(b.&inputVar.,8.)) as factor_gr_label,
					a.pct as pct_dev,
					a.avg_fact as avg_fact_dev,
					b.pct as pct_val,
					b.avg_fact as avg_fact_val
			from DEVELOPMENT_SET as a
			full join VALIDATION_SET as b
				on a.&inputVar. = b.&inputVar
			order by &inputVar.;
		quit;
		
		%let finalReportSet = REPORT_SET;
		
		%if &factorBinLabelSet. ^= 0 %then %do;
			proc sql noprint;
				create table REPORT_SET_LABEL as
				select a.&inputVar.,
						coalesce(c.factor_gr_label, a.factor_gr_label) as factor_gr_label,
						a.pct_dev,
						a.avg_fact_dev,
						a.pct_val,
						a.avg_fact_val
				from REPORT_SET as a
				left join &factorBinLabelSet. as c
					on upcase("&inputVar.") = upcase(c.factor_gr)
					and a.&inputVar. = c.bin_number;
			quit;
			
			%let finalReportSet = REPORT_SET_LABEL;
		%end;
		
		*** Определение размера шрифта для бинов;
		proc sql noprint;
			select max(length(factor_gr_label))
			into :maxLenFactor
			from &finalReportSet.;
		quit;
		
		data _null_;
			if &maxLenFactor. < 40 then letterSize = 8;
			else letterSize = 6;
			call symput('letterSize', letterSize);
		run;
		
		*** Выбор лейбла фактора;
		%let factorLabel = &inputVar.;
		
		%if "&factorLabelSet." ^= "0" %then %do;
			proc sql noprint;
				select factor_label as factor_label
				into :factorLabel
				from &factorLabelSet.
				where upcase(factor) = upcase("&inputVar.");
			quit;
			
			%let factorLabel = &inputVar.: &factorLabel.;
		%end;
		
		Title3 "&factorLabel.";

		proc sgplot data=&finalReportSet.;
			format pct_dev pct_val avg_fact_dev avg_fact_val percentn7.2;
			vbar factor_gr_label /
						response=pct_dev
						legendlabel="Концентрация наблюдений, разработка"
						barwidth=0.15
						transparency=0.2
						discreteoffset=0.15
						dataskin=MATTE;
						
			vbar factor_gr_label /
						response=pct_val
						legendlabel="Концентрация наблюдений, валидация"
						barwidth=0.15
						transparency=0.2
						discreteoffset=-0.15
						dataskin=MATTE;
						
			xaxis display=(nolabel noline noticks) discreteorder=data valueattrs=(size=&letterSize.);
			yaxis display=(noline noticks) label="Концентрация наблюдений";

			vline factor_gr_label /
						response=avg_fact_dev
						y2axis
						datalabel
						lineattrs=(thickness=0.8 mm)
						legendlabel="&y2label., разработка"
						markers;
						
			vline factor_gr_label /
						response=avg_fact_val
						y2axis
						datalabel
						lineattrs=(thickness=0.8 mm pattern=8)
						legendlabel="&y2label., валидация"
						markers;
						
			y2axis display=(noline noticks) label="&y2label.";
		run;
		
		Title1;
	%end;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete DEVELOPMENT_SET VALIDATION_SET REPORT_SET REPORT_SET_LABEL;
	run;

%mend m_group_factor_distribution;


%macro m_roc_curve(rawDataSet=, inputVar=, actualVar=, periodVar=, periodLabelVar=);
	/* 
		Назначение: Построение ROC-кривой для каждого входного периода.
	   
		Параметры:  rawDataSet     - Имя входного набора данных.
					inputVar	   - Имя входной переменной.
					actualVar	   - Имя бинарной фактической переменной.
					periodVar	   - Имя переменной, определяющей период.
					periodLabelVar - Имя переменной, определяющей текстовую метку периода.
	*/
	
	*** Определение периодов;
	proc sql noprint;
		create table PERIOD_LIST as
		select distinct &periodVar., &periodLabelVar.
		from &rawDataSet.
		order by &periodVar.;
		
		select count(*)
		into :periodCnt
		from PERIOD_LIST;
	quit;
	
	%let periodCnt = &periodCnt.;
	
	proc sql noprint;
		select &periodVar.
		into :period1-:period&periodCnt.
		from PERIOD_LIST;
		
		select &periodLabelVar.
		into :periodLabelRoc1-:periodLabelRoc&periodCnt.
		from PERIOD_LIST;
	quit;
		
	%do periodNum = 1 %to &periodCnt.;
		data INPUT_ROC;
			set &rawDataSet.;
			where &periodVar. = &&period&periodNum. and &inputVar. ^= . and &actualVar. ^= .;
			keep &inputVar. &actualVar.;
		run;

		proc sort data=INPUT_ROC;
			by descending &inputVar.;
		run;

		proc sort data=INPUT_ROC out=INPUT_ROC_SORTED;
			by descending &actualVar.;
		run;

		data INPUT_ROC_SORTED;
			set INPUT_ROC_SORTED (keep=&actualVar.);
			rename &actualVar. = actualVarSorted;
		run;

		proc sql noprint;
			select count(*), sum(&actualVar.)
			into :totalCount, :actualVarSum
			from INPUT_ROC;
		quit;
		
		*** Расчет значений, необходимых для построения отчета;
		data REPORT_SET_&periodNum.;
			set INPUT_ROC;
			set INPUT_ROC_SORTED;
			actualVarPercent = &actualVar. / &actualVarSum.;
			actualVarSortedPercent = actualVarSorted / &actualVarSum.;
			retain actualVarPercentCum actualVarSortedPercentCum;
			segmentArea = 0.5 * (actualVarPercentCum * 2 + actualVarPercent) / &totalCount.;
			segmentAreaIdeal = 0.5 * (actualVarSortedPercentCum * 2 + actualVarSortedPercent) / &totalCount.;
			actualVarPercentCum + actualVarPercent;
			actualVarSortedPercentCum + actualVarSortedPercent;
			totalPercent = _N_ / &totalCount.;
			keep totalPercent actualVarSortedPercentCum actualVarPercentCum;
		run;
	%end;
	
	data REPORT_SET;
		set
			%do periodNum=1 %to &periodCnt.;
				REPORT_SET_&periodNum.(rename=(totalPercent=totalPercent_&periodNum.
												actualVarSortedPercentCum=actualVarSortedPercentCum_&periodNum.
												actualVarPercentCum=actualVarPercentCum_&periodNum.))
			%end;
			;
	run;

	proc sgplot data= REPORT_SET;
		%do periodNum=1 %to &periodCnt.;
			series x=totalPercent_&periodNum. y=actualVarSortedPercentCum_&periodNum. / legendlabel = "Идеальная кривая, &&periodLabelRoc&periodNum."
																						lineattrs = (pattern=4);
			series x=totalPercent_&periodNum. y=actualVarPercentCum_&periodNum. / legendlabel = "ROC-кривая, &&periodLabelRoc&periodNum.";
		%end;
		series x=totalPercent_1 y=totalPercent_1 / legendlabel = 'x = y' lineattrs = (color=black);
		
		xaxis display=(noline noticks nolabel);
		yaxis display=(noline noticks nolabel);
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_ROC INPUT_ROC_SORTED REPORT_SET PERIOD_LIST
			%do periodNum=1 %to &periodCnt.;
				REPORT_SET_&periodNum.
			%end;
			;
	run;

%mend m_roc_curve;


%macro m_print_gini(rawDataSet=, actualVar=, inputVarList=, segmentVar=0, periodVar=, periodLabelVar=, factorLabelSet=0,
					yellowThreshold=0.55, redThreshold=0.45, yellowRelativeThreshold=0.05, redRelativeThreshold=0.1, titleNum=1);
	/*
		Назначение: Расчет коэффициента Джини для входных переменных в разрезе сегментов и периодов.
	   
		Параметры:  rawDataSet     - Имя входного набора данных.
					actualVar	   - Имя бинарной фактической переменной.
					inputVarList   - Строка, содержащая перечень имен входных переменных, разделитель - '|'.
								     Пример: variable1|variable2|variable3.
					segmentVar	   - Имя переменной, разбивающей входной набор на сегменты.
									 Значение по умолчанию = 0, в этом случае набор не разбивается по сегментам.
					periodVar      - Имя переменной, определяющей период.
							         Выборка для разработки - periodVar = 1,
								     выборки для валидации - последующие периоды (значения: 2, 3, 4 и т.д.).
					periodLabelVar - Имя переменной, определяющей текстовую метку периода.
					factorLabelSet - Набор данных, содержащий лейблы для факторов.
								     Должен содержать следующий набор полей:
										factor character			- название фактора,
										factor_label character		- лейбл фактора.
									 Значение по умолчанию = 0, в этом случае лейблы и специальные значения не используются.
					yellowThreshold 		- Желтое пороговое значение.
											  Значение по умолчанию = 0,55.
					redThreshold 			- Красное пороговое значение.
											  Значение по умолчанию = 0,45.
					yellowRelativeThreshold - Относительное желтое пороговое значение.
											  Значение по умолчанию = 0,05.
					redRelativeThreshold	- Относительное красное пороговое значение.
											  Значение по умолчанию = 0,1.
					titleNum				- Номер заголовка, необходимо к номеру заголовка перед вызовом макроса прибавить единицу.
											  Значение по умолчанию = 1.
								  
		Результат работы:	Возможны четыре варианта.
								1. Количество переменных = 1, количество сегментов = 1.
								Вывод: каждая строка соответствует периоду,
									   дополнительно строится график тренд Джини.
								2. Количество переменных > 1, количество сегментов = 1.
								Вывод: количество таблиц = количеству периодов, каждая строка соответствует одной переменной.
								3. Количество переменных = 1, количество сегментов > 1.
								Вывод: количество таблиц = количество периодов, каждая строка соответствует одному сегменту.
								4. Количество переменных > 1, количество сегментов > 1.
								Вывод: не поддерживается, в логе появится сообщение об ошибке.
	*/
	
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Определение количества входных переменных;
	%let inputVarCnt=%SYSFUNC(countw(&inputVarList.,%STR('|')));
	
	*** Копирование исходного набора, чтобы избежать изменений;
	data INPUT_PRINT_GINI;
		set &rawDataSet.;
	run;
	
	*** Определение периодов и текстовой метки периодов;
	proc sql noprint;
		create table PERIOD_LABEL as
		select distinct &periodVar., &periodLabelVar.
		from INPUT_PRINT_GINI
		order by &periodVar.;
		
		select count(*)
		into :periodCnt
		from PERIOD_LABEL;
	quit;
	
	%let periodCnt = &periodCnt.;
		
	proc sql noprint;	
		select &periodVar., &periodLabelVar.
		into :period1-:period&periodCnt., :periodLabel1-:periodLabel&periodCnt.
		from PERIOD_LABEL;
	quit;
	
	*** Определение числа сегментов;
	%if &segmentVar. = 0 %then %do;
		%let countSeg = 1;
		%let segmentVar = mv_m_print_gini_segment_var;
		
		data INPUT_PRINT_GINI;
			set INPUT_PRINT_GINI;
			mv_m_print_gini_segment_var = 1;
		run;
	%end;
	%else %do;
		proc sql noprint;
			select count(distinct &segmentVar.)
			into :countSeg
			from INPUT_PRINT_GINI;
		quit;
		
		%let countSeg = &countSeg.;
	%end;
	
	proc sql noprint;
		select distinct &segmentVar.
		into :seg1-:seg&countSeg.
		from INPUT_PRINT_GINI;
	quit;
	
	*** Создание промежуточной таблицы в разрезе сегментов и факторов;
	proc sql noprint;
		create table REPORT_SET_SEGMENT_FACTOR
		(	
			%do periodNum = 1 %to &periodCnt.;
				obs_num_&periodNum.				integer,
				gini_&periodNum.				float format percentn7.2,
				lower_bound_&periodNum. 		float format percentn7.2,
				upper_bound_&periodNum. 		float format percentn7.2,
				light_&periodNum. 				character(50),
				%if &periodNum. ^= 1 %then %do;
					diff_&periodNum. 			float format percentn7.2,
					light_rel_&periodNum.		character(50),
				%end;
			%end;
			segment								character(50),
			factor								character(50)
		);
	quit;
	
	*** Расчет Джини для каждого сегмента, сохранение результата в таблице REPORT_SET_SEGMENT_FACTOR;
	%do segmentNum=1 %to &countSeg.;
		data INPUT_SEG;
			set INPUT_PRINT_GINI (keep= &actualVar. &segmentVar. &periodVar. &periodLabelVar.
									%do varIdx=1 %to &InputVarCnt.;
										%SCAN(%STR(&inputVarList.),&varIdx.,'|')
									%end;
								  );
			where &segmentVar. = &&seg&segmentNum.;
		run;
		
		*** Необходимо сохранить порядок периодов, если значение сегмента в периоде отсутствует, добавляется одна пуская строка;
		proc sql noprint;
			create table INPUT_SEG_&segmentNum. as
			select a.&periodVar.,
					%do varIdx=1 %to &inputVarCnt.;
						b.%SCAN(%STR(&inputVarList.),&varIdx.,'|'),
					%end;
					b.&actualVar.
			from PERIOD_LABEL as a
			left join INPUT_SEG as b
				on a.&periodVar. = b.&periodVar.;
		quit;
		
		*** Создание таблиц для каждого периода, поле factor - имя входной переменной;
		%do periodNum=1 %to &periodCnt.;
			proc sql noprint;
				create table FACTOR_&periodNum.
				(	
					obs_num_&periodNum.	 	integer,
					factor 					character(50),
					gini_&periodNum. 		float format percentn7.2,
					lower_bound_&periodNum. float format percentn7.2,
					upper_bound_&periodNum. float format percentn7.2,
					light_&periodNum. 		character(50)
				);
			quit;
		%end;
		
		*** Цикл по входным переменным;	
		%do varIdx=1 %to &inputVarCnt.;
			%let inputVar=%SCAN(%STR(&inputVarList.),&varIdx.,'|');
			
			*** Цикл по периодам;
			%do periodNum=1 %to &periodCnt.;
			
				*** Создание таблиц для каждой входной переменной в разрезе периодов;
				proc sql noprint;
					create table INPUTVAR_&periodNum. as select
						&actualVar.,
						&inputVar.
					from INPUT_SEG_&segmentNum.
					where &periodVar.=&&period&periodNum.;
				quit;
				
				proc sql noprint;
					select count(*)
					into :countAll
					from INPUTVAR_&periodNum.;
				quit;
				
				*** Расчет количества уникальных значений фактической и текущей входной переменных;
				proc sql noprint;
					select count(distinct &actualVar.),
							count(distinct &inputVar.)
					into :dist_actual_var,
							:dist_output_var
					from INPUTVAR_&periodNum;	
				quit;
				
				*** Вычисление Джини невозможно для периода,								   ;
				*** в котором фактическая или входная переменная принимает только одно значение;
				%if &dist_actual_var. > 1 and &dist_output_var. > 1 %then %do;
				
					*** Рассчет Коэффициента Джини, а также 95%-го доверительного интервала;
					ods exclude all;
					
					proc freq data = INPUTVAR_&periodNum.;
						format &inputVar. 9.3;
						tables &inputVar. * &actualVar. / noprint;
						test smdrc;
						ods output somersdrc = RESULT_SOMERSD;
					run;
					
					ods exclude none;
					
					data RESULT_SOMERSD;
						set RESULT_SOMERSD;
						if Label1 = 'ASE' then delete;
						keep Label1 nValue1;
					run;
					
					proc transpose data=RESULT_SOMERSD out=RESULT_SOMERSD_TRSP;
					run;
					
					data RESULT_SOMERSD_TRSP;
						set RESULT_SOMERSD_TRSP;
						if COL1 >= 0 then do;
							gini = COL1;
							lower_bound = COL2;
							upper_bound = COL3;
						end;
						else do;
							gini = -1 * COL1;
							lower_bound = -1 * COL3;
							upper_bound = -1 * COL2;
						end;
					run;
					
					*** Результат заносится в итоговую для периода таблицу;
					proc sql noprint;
						insert into FACTOR_&periodNum. (obs_num_&periodNum., factor, gini_&periodNum.,
														lower_bound_&periodNum., upper_bound_&periodNum., light_&periodNum.)
						select
							&countAll. as obs_num_&periodNum.,
							"&inputVar." as factor,
							gini as gini_&periodNum.,
							lower_bound as lower_bound_&periodNum.,
							upper_bound as upper_bound_&periodNum.,
							case when lower_bound < &redThreshold. then 'красный'
								when lower_bound < &yellowThreshold. then 'желтый'
								else 'зеленый' end as light_&periodNum.
						from RESULT_SOMERSD_TRSP;  
					quit;
				%end;
				%else %do;
				
					*** Если значение Джини посчитать невозможно, переменная obs_num_&periodNum. принимает значение -1;
					proc sql noprint;
						insert into FACTOR_&periodNum. (obs_num_&periodNum., factor, light_&periodNum.)
						values (
							-1,
							"&inputVar.",
							'красный'
						);
					quit;
				%end;
				
				*** Удаление лишних наборов данных;
				proc datasets nolist;
					delete RESULT_SOMERSD RESULT_SOMERSD_TRSP INPUTVAR_&periodNum;
				run;
				
			%end;
		%end;
		
		*** Сортировка таблиц для последующего объединения;
		%do periodNum=1 %to &periodCnt.;
			proc sort data=FACTOR_&periodNum.;
				by factor;
			run;
		%end;
		
		*** Объединение попериодных таблиц в одну и расчет относительной разницы Джини;
		data ALL_FACTORS_ONE_SEGMENT;
			merge 
				%do periodNum=1 %to &periodCnt.;
					FACTOR_&periodNum.
				%end;
			;
			by Factor;
			format
				%do periodNum=2 %to &periodCnt.;
					diff_&periodNum.
				%end;
			percentn7.2;
			format
				%do periodNum=2 %to &periodCnt.;
					light_rel_&periodNum.
				%end;
			$char50.;
			
			%do periodNum=2 %to &periodCnt.;
				diff_&periodNum. = (gini_&periodNum.-gini_1) / gini_1;
				select;
					when (abs(diff_&periodNum.) > &redRelativeThreshold. or
						  diff_&periodNum. = .)								 light_rel_&periodNum. = "красный";
					when (abs(diff_&periodNum.) > &yellowRelativeThreshold.) light_rel_&periodNum. = "желтый";
					otherwise												 light_rel_&periodNum. = "зеленый";
				end;
			%end;
		run;
		
		proc sql noprint;
			insert into REPORT_SET_SEGMENT_FACTOR
			(
			%do periodNum = 1 %to &periodCnt.;
				obs_num_&periodNum.,
				gini_&periodNum.,
				lower_bound_&periodNum.,
				upper_bound_&periodNum.,
				light_&periodNum.,
				%if &periodNum. ^= 1 %then %do;
					diff_&periodNum.,
					light_rel_&periodNum.,
				%end;
			%end;
			segment,
			factor
			)
			select
				%do periodNum = 1 %to &periodCnt.;
					obs_num_&periodNum.,
					gini_&periodNum.,
					lower_bound_&periodNum.,
					upper_bound_&periodNum.,
					light_&periodNum.,
					%if &periodNum. ^= 1 %then %do;
						diff_&periodNum.,
						light_rel_&periodNum.,
					%end;
				%end;
				"&&seg&segmentNum." as segment,
				factor
			from ALL_FACTORS_ONE_SEGMENT;
		quit;
	%end;
	
	*** Если переменная одна и разбиения по сегментам нет, то вывод результатов осуществляется в одной таблице, строка соответствует периоду;
	*** Если переменных несколько и разбиения по сегментам нет, то вывод осуществляется отдельно для каждого периода, строка соответствует переменной;
	*** Если переменная одна и разбиения по сегментам есть, то вывод осуществляется отдельно для каждого периода, строка соответствует сегменту;
	%if &inputVarCnt. = 1 and &countSeg. = 1 %then %do;
		
		*** Создание таблицы для вывода;
		proc sql noprint;
			create table REPORT_GINI
			(
				period_label character(50),
				obs_num integer,
				gini float format percentn7.2,
				lower_bound float format percentn7.2,
				upper_bound float format percentn7.2,
				light character(50),
				diff float format percentn7.2,
				light_rel character(50)
			);
		quit;
		
		*** Заполнение таблицы;
		proc sql noprint;
			insert into REPORT_GINI (period_label, obs_num, gini, lower_bound, upper_bound, light)
			select "&periodLabel1." as period_label,
					obs_num_1 as obs_num,
					gini_1 as gini,
					lower_bound_1 as lower_bound,
					upper_bound_1 as upper_bound,
					light_1 as light
			from REPORT_SET_SEGMENT_FACTOR;
		
			%do periodNum=2 %to &periodCnt.;
				insert into REPORT_GINI (period_label, obs_num, gini, lower_bound, upper_bound, light, diff, light_rel)
				select "&&periodLabel&periodNum." as period_label,
					obs_num_&periodNum. as obs_num,
					gini_&periodNum. as gini,
					lower_bound_&periodNum. as lower_bound,
					upper_bound_&periodNum. as upper_bound,
					light_&periodNum. as light,
					diff_&periodNum. as diff,
					light_rel_&periodNum. as light_rel
				from REPORT_SET_SEGMENT_FACTOR;
			%end;
		quit;
		
		*** Вывод результатов;
		proc report data=REPORT_GINI SPLIT="";
			column period_label obs_num gini lower_bound upper_bound light diff light_rel;
			define period_label /	display "Период"
									style(column)=[fontsize=1]
									style(header)=[fontsize=1];
			define obs_num /	display "Число наблюдений"
								style(header)=[fontsize=1];
			define gini /	display "Джини"
							style(header)=[fontsize=1];
			define lower_bound /	display "Нижняя граница"
									style(header)=[fontsize=1];
			define upper_bound /	display "Верхняя граница"
									style(header)=[fontsize=1];
			define light /	display "Светофор, абсолютное значение"
							style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
							style(header)=[fontsize=1];
			define diff /	display "Относительная разница"
							style(header)=[fontsize=1];
			define light_rel /	display "Светофор, Относительная разница"
								style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
								style(header)=[fontsize=1];
		run;
		
		Title1;
		Title1 h=12pt "Тренд Джини";
	
		proc sgplot data=REPORT_GINI;
			vline period_label /
						response=gini
						datalabel
						lineattrs=(thickness=0.8 mm)
						markers;
			
			xaxis display=(noline noticks) label="Период" discreteorder=data;
			yaxis display=(noline noticks) label="Индекс Джини" min=0 max=1;
		run;
		
		Title1;
	%end;
	%else %if &inputVarCnt. > 1 and &countSeg. = 1 %then %do;
	
		*** Выбор лейбла фактора;
		%if "&factorLabelSet." = "0" %then %do;
			data REPORT_GINI;
				set REPORT_SET_SEGMENT_FACTOR;
			run;
		%end;
		%else %do;
			proc sql noprint;
				create table REPORT_GINI as
				select a.*,
					trim(b.factor_label) as factor_label
				from REPORT_SET_SEGMENT_FACTOR as a
				left join &factorLabelSet. as b
					on upcase(a.factor) = upcase(b.factor);
			quit;
			
			Title&titleNum. h=12pt "Список и наименование факторов";
			
			proc report data=REPORT_GINI SPLIT='';
				column factor factor_label;
				define factor / display "Фактор"
								style(column)=[fontsize=1]
								style(header)=[fontsize=1];
				define factor_label /	display "Наименование фактора"
										style(column)=[cellwidth=4in fontsize=1]
										style(header)=[fontsize=1]; 
			run;
			
			Title1;
		%end;
		
		%do periodNum=1 %to &periodCnt.;
			Title&titleNum. h=12pt "Период: &&periodLabel&periodNum.";
			
			proc report data=REPORT_GINI SPLIT='';
				column factor gini_&periodNum. lower_bound_&periodNum. upper_bound_&periodNum.
						light_&periodNum.
					%if &periodNum. > 1 %then %do;
						diff_&periodNum. light_rel_&periodNum.;
					%end;
					;
				define factor / display "Фактор"
								style(column)=[fontsize=1]
								style(header)=[fontsize=1];
				define gini_&periodNum. /	display "Джини"
											style(header)=[fontsize=1];
				define lower_bound_&periodNum. /	display "Нижняя граница"
													style(header)=[fontsize=1];
				define upper_bound_&periodNum. /	display "Верхняя граница"
													style(header)=[fontsize=1];
				define light_&periodNum. /  display "Светофор, абсолютное значение"
											style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
											style(header)=[fontsize=1];
				%if &periodNum. > 1 %then %do;
					define diff_&periodNum. /	display "Относительная разница"
												style(header)=[fontsize=1];
					define light_rel_&periodNum. /  display "Светофор, относительная разница"
													style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
													style(header)=[fontsize=1];
				%end;
			run;
			
			Title1;
		%end;
	%end;
	%else %if &inputVarCnt. = 1 and &countSeg. > 1 %then %do;
		
		*** Выбор лейбла фактора;
		%if "&factorLabelSet." = "0" %then %do;
			data REPORT_GINI;
				set REPORT_SET_SEGMENT_FACTOR;
				rename segment = factor_label;
			run;
		%end;
		%else %do;
			proc sql noprint;
				create table REPORT_GINI as
				select a.*,
						trim(a.segment) || ': ' || trim(b.factor_label) as factor_label
				from REPORT_SET_SEGMENT_FACTOR as a
				left join &factorLabelSet. as b
					on upcase(a.segment) = upcase(b.factor);
			quit;
		%end;
		
		%do periodNum=1 %to &periodCnt.;
			Title&titleNum. h=12pt "Период: &&periodLabel&periodNum.";
			
			proc report data=REPORT_GINI SPLIT='';
				column factor_label	obs_num_&periodNum. gini_&periodNum. lower_bound_&periodNum. upper_bound_&periodNum.
						light_&periodNum.
					%if &periodNum. > 1 %then %do;
						diff_&periodNum. light_rel_&periodNum.;
					%end;
					;
				define factor_label /	display "Сегмент"
										style(header)=[fontsize=1]
										style(column)=[cellwidth=1in fontsize=1];
				define obs_num_&periodNum. /	display "Число наблюдений"
												style(header)=[fontsize=1];
				define gini_&periodNum. /	display "Джини"
											style(header)=[fontsize=1];
				define lower_bound_&periodNum. /	display "Нижняя граница"
													style(header)=[fontsize=1];
				define upper_bound_&periodNum. /	display "Верхняя граница"
													style(header)=[fontsize=1];
				define light_&periodNum. /	display "Светофор, абсолютное значение"
											style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
											style(header)=[fontsize=1];
				%if &periodNum. > 1 %then %do;
					define diff_&periodNum. /	display "Относительная разница"
												style(header)=[fontsize=1];
					define light_rel_&periodNum. /	display "Светофор, Относительная разница"
													style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
													style(header)=[fontsize=1];
				%end;
			run;
			
			Title1;
		%end;
	%end;
	%else %do;
		%put ERROR: Число сегментов и число переменных одновременно не могут превышать единицу;
	%end;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_PRINT_GINI PERIOD_LABEL REPORT_SET_SEGMENT_FACTOR INPUT_SEG ALL_FACTORS_ONE_SEGMENT REPORT_GINI PERIOD_SET
			%do segmentNum=1 %to &countSeg.;
				INPUT_SEG_&segmentNum.
			%end;
			%do periodNum=1 %to &periodCnt.;
				FACTOR_&periodNum.
			%end;
		;
	run;
	
%mend m_print_gini;


%macro m_get_ks(rawDataSet=, scoreVar=, actualVar=);
	/* 
		Назначение: Построение графика критерия согласия Колмогорова-Смирнова для одного периода.
		
		Параметры:  rawDataSet      - Имя входного набора данных.
					scoreVar	    - Имя переменной, содержащей Скор-баллы.
					actualVar	    - Имя бинарной фактической переменной.
	*/
	
	*** Копирование исходного набора, чтобы избежать изменений;
	data INPUT_KS;
		set &rawDataSet. (keep= &scoreVar. &actualVar.);
	run;

	proc sort data=INPUT_KS out=INPUT_KS_SORTED;
		by &scoreVar.;
	run;
	
	proc sql noprint;
		select count(*)
		into :count1
		from INPUT_KS_SORTED
		where &actualVar. = 1;
		
		select count(*)
		into :count0
		from INPUT_KS_SORTED
		where &actualVar. = 0;
	quit;
	
	data KS_SORTED_1;
		set INPUT_KS_SORTED;
		where &actualVar. = 1;
		cumulative_pct_1 = _N_ / &count1.;
		drop &actualVar.;
	run;
	
	data KS_SORTED_1;
		set KS_SORTED_1;
		by &scoreVar.;
		if last.&scoreVar.;
	run;
	
	data KS_SORTED_0;
		set INPUT_KS_SORTED;
		where &actualVar. = 0;
		cumulative_pct_0 = _N_ / &count0.;
		drop &actualVar.;
	run;
	
	data KS_SORTED_0;
		set KS_SORTED_0;
		by &scoreVar.;
		if last.&scoreVar.;
	run;
	
	data REPORT_KS;
		merge KS_SORTED_0 KS_SORTED_1;
		by &scoreVar.;
		diff = cumulative_pct_1 - cumulative_pct_0;
	run;
	
	proc sql noprint;
		create table KSD_VALUE as
		select &scoreVar., diff
		from REPORT_KS
		where diff = (select max(diff) from REPORT_KS);
	quit;
	
	data KSD_VALUE;
		set KSD_VALUE (obs=1);
		call symput('KSDScore', &scoreVar.);
		call symput('diff', diff);
	run;
	
	%let KSDScore = &KSDScore.;
		
	proc sgplot data=REPORT_KS;
		series x=&scoreVar. y=cumulative_pct_1 / legendlabel = "В дефолте";		
		series x=&scoreVar. y=cumulative_pct_0 / legendlabel = "Не в дефолте";
		refline &KSDScore. / axis=x label = "KSD: %sysfunc(putn(&diff., percentn7.2)), Score: &KSDScore.";
						
		xaxis display=(noline noticks) label = "Скор-балл";
		yaxis display=(noline noticks) label = "Доля";
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_KS INPUT_KS_SORTED KS_SORTED_0 KS_SORTED_1 REPORT_KS KSD_VALUE;
	run;

%mend m_get_ks;


%macro m_kolmogorov_smirnov(rawDataSet=, scoreVar=, actualVar=, periodVar=, periodLabelVar=, yellowThreshold=0.4, redThreshold=0.3);
	/* 
		Назначение: Построение графиков критерия согласия Колмогорова-Смирнова для данных разработки и валидации,
					графическое изображение тренда Колмогорова-Смирнова.
		
		Параметры:  rawDataSet      - Имя входного набора данных.
					scoreVar	    - Имя переменной, содержащей Скор-баллы.
					actualVar	    - Имя бинарной фактической переменной.
					periodVar       - Имя переменной, определяющей период.
							          Выборка для разработки - periodVar = 1,
								      выборки для валидации - последующие периоды (значения: 2, 3, 4 и т.д.).
					periodLabelVar  - Имя переменной, определяющей текстовую метку периода.
					yellowThreshold - Желтое пороговое значение.
									  Значение по умолчанию = 0,4.
					redThreshold 	- Красное пороговое значение.
									  Значение по умолчанию = 0,3.
					
		Вызываемые макросы:
					m_get_ks	 - Построение графика критерия согласия Колмогорова-Смирнова.
	*/
				
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Копирование исходного набора, чтобы избежать изменений;
	data INPUT_SET;
		set &rawDataSet. (keep= &scoreVar. &actualVar. &periodVar. &periodLabelVar.);
	run;
	
	*** Определение максимального значения периода валидации;
	proc sql noprint;
		select max(&periodVar.)
		into :maxPeriod
		from INPUT_SET;
	quit;
	
	
	***																					   ;
	*** Построение графика критерия согласия Колмогорова-Смирнова на выборке для разработки;
	***																					   ;
	
	data INPUT_KS_DEV;
		set INPUT_SET;
		where &periodVar.=1;
	run;
	
	Title3 "Графическое изображение результатов теста Колмогорова-Смирнова на выборке для разработки";
	
	%m_get_ks(rawDataSet=INPUT_KS_DEV, scoreVar=&scoreVar., actualVar=&actualVar.);
	
	Title1;
	
	
	***																					  ;
	*** Построение графика критерия согласия Колмогорова-Смирнова на выборке для валидации;
	***																					  ;
	
	data INPUT_KS_VAL;
		set INPUT_SET;
		where &periodVar.=&maxPeriod.;
	run;
	
	Title3 "Графическое изображение результатов теста Колмогорова-Смирнова на выборке для валидации";
	
	%m_get_ks(rawDataSet=INPUT_KS_VAL, scoreVar=&scoreVar., actualVar=&actualVar.);
	
	Title1;
	
	
	***												 ;
	*** Построение графика "Тренд Колмогоров-Смирнов";
	***												 ;

	proc sort data=INPUT_SET;
		by &periodVar.;
	run;

	ods exclude all;

	proc npar1way data=INPUT_SET;
		by &periodVar. &periodLabelVar.;
		var &scoreVar.;
		class &actualVar.;
		ods output KS2Stats = TREND_REPORT_SET;
	run;

	ods exclude none;
	
	* Итоговый набор для построение графика тренда;
	data TREND_REPORT_SET(keep=&periodVar. &periodLabelVar. KSD light);
		set TREND_REPORT_SET;
		format light $50.;
		format nValue2 percentn7.2;
		where Name2 = '_D_';
		select;
			when (nValue2 < &redThreshold.)		light='красный';
			when (nValue2 < &yellowThreshold.)	light='желтый';
			otherwise							light='зеленый';
		end;
		rename nValue2 = KSD;
	run;
	
	Title3 "Тренд Колмогоров-Смирнов";
	Title4 h=12pt justify=left
	"Желтая зона: %sysfunc(putn(&redThreshold., percentn7.2)) - %sysfunc(putn(&yellowThreshold., percentn7.2)), красная зона: < %sysfunc(putn(&redThreshold., percentn7.2)).";
	
	proc print data=TREND_REPORT_SET noobs label;
		var &periodLabelVar. KSD;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label 	&periodLabelVar.="Период"
				light="Светофор";
	run;
	
	Title1;
	
	proc sgplot data=TREND_REPORT_SET;
		vline &periodLabelVar. /
					response=KSD
					datalabel
					lineattrs=(thickness=0.8 mm)
					markers;
		
		xaxis display=(noline noticks) label="Период" discreteorder=data;
		yaxis display=(noline noticks) label="Статистика Колмогорова-Смирнова" min=0 max=1;
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_SET INPUT_KS_DEV INPUT_KS_VAL TREND_REPORT_SET;
	run;
	
%mend m_kolmogorov_smirnov;


%macro m_calibration_prepare(rawDataSet=, outputVar=, actualVar=, scaleVar=);
	/* 
		Назначение: Подготовительный шаг для калибровочных тестов.
		
		Параметры:  rawDataSet   - Имя входного набора данных.
					outputVar	 - Имя выходной переменной модели.
					actualVar	 - Имя бинарной фактической переменной.
					scaleVar	 - Имя переменной рейтинговой шкалы.
					
		Выходные таблицы:		 - OUTPUT_M_CALIBRATION_PREPARE
								   (
									&scaleVar.,
									frequency integer,
									mean_PD float,
									default_rate_i float
								   )
								   frequency - количество наблюдений в разрезе scaleVar,
								   mean_PD - среднее значение PD в разрезе scaleVar,
								   default_rate_i - доля дефолтных договоров в разрезе scaleVar.
								   
								  - OUTPUT_M_CALIB_PREP_TOTAL
								    (
									frequency integer,
									mean_PD_tot float,
									default_rate_tot float
								   )
								   frequency - количество наблюдений,
								   mean_PD_tot - среднее значение PD,
								   default_rate_tot - доля дефолтных договоров.
	*/

	*** Копирование исходного набора, чтобы избежать изменений;
	data VALIDATION_SET;
		set &rawDataSet. (keep= &outputVar. &actualVar. &scaleVar.);
		format &actualVar. 9.6;
	run;
	
	proc sort data=VALIDATION_SET;
		by &scaleVar.;
	run;
	
	*** Расчет среднего PD и коэффициента дефолтов;
	proc means data=VALIDATION_SET noprint;
		output out=OUTPUT_M_CALIB_PREP_TOTAL mean(&outputVar. &actualVar.) = mean_PD_tot default_rate_tot;
	run;
	
	data OUTPUT_M_CALIB_PREP_TOTAL;
		set OUTPUT_M_CALIB_PREP_TOTAL (drop=_TYPE_);
		rename _FREQ_ = frequency;
	run;
	
	*** Расчет среднего значения PD и коэффициента дефолтов в разрезе значений рейтинговой шкалы;
	proc means data=VALIDATION_SET noprint;
		by &scaleVar.;
		output out=OUTPUT_M_CALIBRATION_PREPARE mean(&outputVar. &actualVar.) = mean_PD default_rate_i;
	run;
	
	data OUTPUT_M_CALIBRATION_PREPARE;
		set OUTPUT_M_CALIBRATION_PREPARE (drop=_TYPE_);
		rename _FREQ_ = frequency;
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete VALIDATION_SET;
	run;

%mend m_calibration_prepare;


%macro m_hosmer_lemeshow(dataSetByScale=, scaleVar=, centralTrend=, defaultRateTot=, BayesFlg=, yellowThreshold=0.1, redThreshold=0.05);
	/* 
		Назначение: Проведение теста Хосмера-Лемешова.
		
		Параметры:  dataSetByScale   - Имя входного набора данных, сгенерированного макросом m_calibration_prepare.
					scaleVar		 - Имя переменной рейтинговой шкалы.
					centralTrend	 - Значение центральной тенденции.
					defaultRateTot	 - Коэффициент дефолта на всей выборке для валидации.
					BayesFlg		 - Флаг (1 - использовать корректировку Байеса, 0 - не использовать).
					yellowThreshold  - Желтое пороговое значение.
									   Значение по умолчанию = 0,1.
					redThreshold 	 - Красное пороговое значение.
									   Значение по умолчанию = 0,05.
	*/
	
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Копирование исходного набора, чтобы избежать изменений;
	data INPUT_SET;
		set &dataSetByScale.;
	run;
	
	*** Определение количества значений рейтинговой шкалы;
	proc sql noprint;
		select count(*)
		into :scaleNum
		from INPUT_SET;
	quit;
	
	*** Корректировка Байеса;
	%if &BayesFlg. = 1 %then %do;
		data INPUT_SET (rename=(default_rate_bayes_i=default_rate_i));
			set INPUT_SET;
			default_rate_bayes_i = default_rate_i * (&centralTrend. / &defaultRateTot.) /
			((1 - default_rate_i) * (1 - &centralTrend.) / (1 - &defaultRateTot.) + default_rate_i * &centralTrend. / &defaultRateTot.);
			drop default_rate_i;
		run;
	%end;
	
	*** Расчет значения хи-квадрат;
	data CHI_SET;
		set INPUT_SET;
		format mean_PD default_rate_i percentn7.2;
		chi = ((frequency * mean_PD - frequency * default_rate_i) ** 2) / (frequency * mean_PD * (1 - mean_PD));
	run;
	
	proc print data=CHI_SET noobs label;
		var &scaleVar. frequency mean_PD default_rate_i chi;
		label   &scaleVar.="Рейтинг"
				mean_PD="Расчетные значения PD(%)"
				default_rate_i="Частота дефолтов(%)"
				frequency="Частота наблюдений"
				chi="Статистика хи-квадрат для разряда рейтинговой шкалы";
	run;
	
	Title1;
	
	*** Расчет статистики Хосмера-Лемешова;
	proc means data=CHI_SET noprint;
		output out=REPORT_SET_HL sum(chi) = stat_HL;
	run;

	*** Расчет p-value;
	data REPORT_SET_HL;
		set REPORT_SET_HL(drop= _FREQ_ _TYPE_);
		format p_value percentn7.2 light $50.;
		p_value = 1 - probchi(stat_HL, &scaleNum.);
		select;
			when (p_value < &redThreshold.) 	light='красный';
			when (p_value < &yellowThreshold.)  light='желтый';
			otherwise			  				light='зеленый';
		end;
	run;
	
	proc print data=REPORT_SET_HL noobs label;
		var stat_HL p_value;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label   stat_HL="Значение статистики Хосмера-Лемешова"
				p_value="pValue"
				light="Светофор";
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_SET CHI_SET REPORT_SET_HL;
	run;

%mend m_hosmer_lemeshow;


%macro m_binomial_test(centralTrend=, meanPDTot=, countNum=, confLevelYellow=0.95, confLevelRed=0.99);
	/* 
		Назначение: Проведение биномиального теста на точность уровня калибровки.
		
		Параметры:  centralTrend	- Значение центральной тенденции.
					meanPDTot		- Среднее значение PD на выборке для валидации.
					countNum		- Общее число наблюдений.
					confLevelYellow - Желтый доверительный интервал.
									  Значение по умолчанию = 0,95.
					confLevelRed	- Красный доверительный интервал.
									  Значение по умолчанию = 0,99.
	*/
				
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Расчет данных для отчета;
	data REPORT_SET;
		central_trend = &centralTrend.;
		mean_PD_tot = &meanPDTot.;
		PD_lower_yellow = probit(1 - &confLevelYellow.) * sqrt(mean_PD_tot * (1 - mean_PD_tot) / &countNum.) + mean_PD_tot;
		PD_upper_yellow = probit(&confLevelYellow.) * sqrt(mean_PD_tot * (1 - mean_PD_tot) / &countNum.) + mean_PD_tot;
		PD_lower_red = probit(1 - &confLevelRed.) * sqrt(mean_PD_tot * (1 - mean_PD_tot) / &countNum.) + mean_PD_tot;
		PD_upper_red = probit(&confLevelRed.) * sqrt(mean_PD_tot * (1 - mean_PD_tot) / &countNum.) + mean_PD_tot;
		format light $50.;
		select;
			when (PD_lower_red > central_trend or PD_upper_red < central_trend)			light='красный';
			when (PD_lower_yellow > central_trend or PD_upper_yellow < central_trend) 	light='желтый';
			otherwise																	light='зеленый';
		end;
	run;
	
	proc print data=REPORT_SET noobs label;
		var central_trend mean_PD_tot PD_lower_yellow PD_upper_yellow PD_lower_red PD_upper_red;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		format mean_PD_tot central_trend PD_lower_yellow PD_upper_yellow PD_lower_red PD_upper_red percentn7.2;
		label   central_trend="Значение центральной тенденции(%)"
				mean_PD_tot="PD-результат теста"
				PD_lower_yellow="Нижняя граница(желт.)"
				PD_upper_yellow="Верхняя граница(желт.)" 
				PD_lower_red="Нижняя граница(красн.)"
				PD_upper_red="Верхняя граница(красн.)"
				light="Светофор";
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete REPORT_SET;
	run;
	
%mend m_binomial_test;


%macro m_scale_curve_accuracy(dataSetByScale=, scaleVar=, centralTrend=, defaultRateTot=, BayesFlg=, isPlotFlg=, confLevelYellow=0.95, confLevelRed=0.99);
	/* 
		Назначение: Проведение теста на точность калибровочной кривой,
					построение графика теста.
		
		Параметры:  dataSetByScale   - Имя входного набора данных, сгенерированного макросом m_calibration_prepare.
					scaleVar		 - Имя переменной рейтинговой шкалы.
					centralTrend	 - Значение центральной тенденции.
					defaultRateTot	 - Коэффициент дефолта на всей выборке для валидации.
					BayesFlg		 - Флаг (1 - использовать корректировку Байеса, 0 - не использовать).
					isPlotFlg		 - Флаг (1 - построить график, 0 - не строить график).
					confLevelYellow  - Желтый доверительный интервал.
									   Значение по умолчанию = 0,95.
					confLevelRed	 - Красный доверительный интервал.
									   Значение по умолчанию = 0,99.
	*/
				
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Копирование исходного набора, чтобы избежать изменений;
	data INPUT_SET;
		set &dataSetByScale.;
	run;
	
	*** Корректировка Байеса;
	%if &BayesFlg. = 1 %then %do;
		data INPUT_SET (rename=(default_rate_bayes_i=default_rate_i));
			set INPUT_SET;
			default_rate_bayes_i = default_rate_i * (&centralTrend. / &defaultRateTot.) /
			((1 - default_rate_i) * (1 - &centralTrend.) / (1 - &defaultRateTot.) + default_rate_i * &centralTrend. / &defaultRateTot.);
			drop default_rate_i;
		run;
	%end;
	
	data RESULT_SET;
		set INPUT_SET;
		format light $50.;
		format default_rate_i mean_PD PD_upper_yellow PD_lower_yellow PD_lower_red PD_upper_red percentn7.2;
		PD_lower_yellow = max(probit(1 - &confLevelYellow.) * sqrt(mean_PD * (1 - mean_PD) / frequency) + mean_PD, 0);
		PD_upper_yellow = min(probit(&confLevelYellow.) * sqrt(mean_PD * (1 - mean_PD) / frequency) + mean_PD, 1);
		PD_lower_red = max(probit(1 - &confLevelRed.) * sqrt(mean_PD * (1 - mean_PD) / frequency) + mean_PD, 0);
		PD_upper_red = min(probit(&confLevelRed.) * sqrt(mean_PD * (1 - mean_PD) / frequency) + mean_PD, 1);
		select;
			when (pd_lower_red > default_rate_i or pd_upper_red < default_rate_i) 		light='красный';
			when (pd_lower_yellow > default_rate_i or pd_upper_yellow < default_rate_i) light='желтый';
			otherwise																	light='зеленый';
		end;
		if light = 'зеленый' then interpretation = 'соответствие';
		else if mean_PD > default_rate_i then interpretation = 'переоценка';
		else interpretation = 'недооценка';
	run;
	
	proc report data=RESULT_SET SPLIT='';
		column &scaleVar. frequency default_rate_i mean_PD light interpretation
				PD_lower_yellow PD_upper_yellow PD_lower_red PD_upper_red;
		define &scaleVar. / display "Рейтинг";
		define frequency / display "Число наблюдений";
		define default_rate_i / display "Частота дефолтов(%)";
		define mean_PD / display "PD-результат теста";
		define light / display "Светофор"
					   style(column)=[backgroundcolor=$BACKCOLOR_FMT.];
		define interpretation / display "Интерпретация";
		define PD_lower_yellow / display "Нижняя граница(желт.)";
		define PD_upper_yellow / display "Верхняя граница(желт.)";
		define PD_lower_red / display "Нижняя граница(красн.)";
		define PD_upper_red / display "Верхняя граница(красн.)";
		compute interpretation;
			if light = "зеленый" then
				call define(_col_,"style","style={background=vlig}");
			else if light = "желтый" then
				call define(_col_,"style","style={background=yellow}");
			else
				call define(_col_,"style","style={background=salmon}");
		endcomp;
	run;
	
	Title1;
	
	*** Построение графика;
	%if &isPlotFlg. = 1 %then %do;
	
		*** Расчет общего числа наблюдений;
		proc sql noprint;
			select sum(frequency)
			into :countNum
			from INPUT_SET
		quit;
		
		data RESULT_SET_SCUTTER (keep=&scaleVar. freqPct PD_lower PD_upper default_rate_i);
			set RESULT_SET;
			format freqPct PD_lower PD_upper percentn7.2;
			freqPct = frequency / &countNum.;
			select;
				when (light='зеленый') do;
					PD_lower = PD_lower_yellow;
					PD_upper = PD_upper_yellow;
				end;
				otherwise do; 
					PD_lower = PD_lower_red;
					PD_upper = PD_upper_red;
				end;
			end;
		run;
		
		%if &BayesFlg. = 1 %then
		Title3 h=12pt justify=left "Графические результаты биномиального теста с применением корректировки Байеса";
		%else
		Title3 h=12pt justify=left "Графические результаты биномиального теста без применения корректировки Байеса";
		;
		
		proc template;
			define statgraph barscatter;
			begingraph;
			layout  overlay / xaxisopts=(label="Рейтинг");
			barchart 	x=&scaleVar.
						y=freqPct / yaxis=y2
						stat=sum
						name="a"
						legendlabel="Доля наблюдений"
						barwidth=0.6;
			scatterplot x=&scaleVar.
						y=default_rate_i/yerrorlower=PD_lower
						yerrorupper=PD_upper
						name="b"
						legendlabel="Частота дефолтов";
			discretelegend "a" "b";
			endlayout;
			endgraph;
			end;
		run;
		
		proc sgrender data=RESULT_SET_SCUTTER template=barscatter;
			label freqPct="Доля наблюдений";
			label default_rate_i="Уровень дефолта";
		run;
		
		Title1;
	%end;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_SET RESULT_SET_SCUTTER RESULT_SET;
	quit;
	
%mend m_scale_curve_accuracy;


%macro m_full_calibration_test(rawDataSet=, outputVar=, actualVar=, scaleVar=, centralTrend=, thresholdSet=);
	/* 
		Назначение: Запуск тестов на точность калибровки.
		
		Параметры:  rawDataSet   - Имя входного набора данных.
					outputVar	 - Имя выходной переменной модели.
					actualVar	 - Имя бинарной фактической переменной.
					scaleVar	 - Имя переменной рейтинговой шкалы.
					centralTrend - Значение центральной тенденции.
					thresholdSet - Набор данных, содержащий пороговые значения.
								   Должен содержать следующий набор полей:
										macro_name character 		- название макроса,
										yellow_threshold float		- желтое пороговое значение,
										red_threshold float			- красное пороговое значение,
										yellow_confidence_lvl		- желтый доверительный интервал,
										red_confidence_lvl			- красный доверительный интервал.
					
		Вызываемые макросы:
					m_calibration_prepare	- Подготовка данных для проведения калибровки.
					m_hosmer_lemeshow		- Тест Хосмера-Лемешова.
					m_binomial_test			- Биномиальный тест.
					m_scale_curve_accuracy	- Тест на точность калибровочной кривой.
	*/
	
	*** Вызов подготовительного макроса, создаются таблицы OUTPUT_M_CALIBRATION_PREPARE OUTPUT_M_CALIB_PREP_TOTAL;
	%m_calibration_prepare(rawDataSet=&rawDataSet., outputVar=&outputVar., actualVar=&actualVar., scaleVar=&scaleVar.);
	
	*** Расчет общего числа наблюдений, среднего PD, а также коэффициента дефолтов на всей выборке для валидации;
	proc sql noprint;
		select frequency, mean_PD_tot, default_rate_tot
		into :countNum, :meanPDTot, :defaultRateTot
		from OUTPUT_M_CALIB_PREP_TOTAL;
	quit;
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_hosmer_lemeshow';
	quit;
		
	Title3 h=12pt justify=left "3.1. Тест на точность оценки PD (тест хи-квадрат Хосмера-Лемешова)";
	Title4 h=12pt justify=left
	"Желтая зона: %sysfunc(putn(&redThreshold., percentn7.2)) - %sysfunc(putn(&yellowThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redThreshold., percentn7.2)).";
	Title5 h=12pt justify=left "Результаты теста Хосмера-Лемешова без применения корректировки Байеса";
	
	%m_hosmer_lemeshow(dataSetByScale=OUTPUT_M_CALIBRATION_PREPARE, scaleVar=&scaleVar., centralTrend=&centralTrend., defaultRateTot=&defaultRateTot.,
					   BayesFlg=0, yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	Title1;
	
	Title5 h=12pt justify=left "Результаты теста Хосмера-Лемешова с применением корректировки Байеса";
	
	%m_hosmer_lemeshow(dataSetByScale=OUTPUT_M_CALIBRATION_PREPARE, scaleVar=&scaleVar., centralTrend=&centralTrend., defaultRateTot=&defaultRateTot.,
					   BayesFlg=1, yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	Title1;
					   
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_confidence_lvl, red_confidence_lvl
		into :confLevelYellow, :confLevelRed
		from &thresholdSet.
		where macro_name = 'm_binomial_test';
	quit;
	
	Title2 h=12pt justify=left "3.2. Тест на точность уровня калибровки (биномиальный)";
	
	%m_binomial_test(centralTrend=&centralTrend., meanPDTot=&meanPDTot., countNum=&countNum., confLevelYellow=&confLevelYellow., confLevelRed=&confLevelRed.);
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_confidence_lvl, red_confidence_lvl
		into :confLevelYellow, :confLevelRed
		from &thresholdSet.
		where macro_name = 'm_scale_curve_accuracy';
	quit;
	
	Title1;
	Title2 h=12pt justify=left "3.3. Тест на точность калибровочной кривой";
	Title3 h=12pt justify=left "Тест на точность калибровочной кривой без применения корректировки Байеса";
	
	%m_scale_curve_accuracy(dataSetByScale=OUTPUT_M_CALIBRATION_PREPARE, scaleVar=&scaleVar., centralTrend=&centralTrend.,
							defaultRateTot=&defaultRateTot., BayesFlg=0, isPlotFlg=0, confLevelYellow=&confLevelYellow., confLevelRed=&confLevelRed.);
	
	Title3 h=12pt justify=left "Тест на точность калибровочной кривой с применением корректировки Байеса";
	
	%m_scale_curve_accuracy(dataSetByScale=OUTPUT_M_CALIBRATION_PREPARE, scaleVar=&scaleVar., centralTrend=&centralTrend.,
							defaultRateTot=&defaultRateTot., BayesFlg=1, isPlotFlg=1, confLevelYellow=&confLevelYellow., confLevelRed=&confLevelRed.);
							
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete OUTPUT_M_CALIBRATION_PREPARE OUTPUT_M_CALIB_PREP_TOTAL;
	quit;
	
%mend m_full_calibration_test;


%macro m_get_psi(rawDataSet1=, rawdataset2=, inputVarList=);
	/* 
		Назначение: Для каждой переменной из inputVarList рассчитывается PSI.
	   
		Параметры:  rawDataSet1  - Имя набора данных для валидации.
					rawDataSet2	 - Имя набора данных разработки.
					inputVarList - Строка, содержащая перечень имен входных переменных, разделитель - '|'.
								   Пример: variable1|variable2|variable3.
								  
		Выходная таблица:		 - OUTPUT_M_GET_PSI
								   (
									factor character(50),
									PSI float format 9.2
								   )
								   Переменная factor содержит имена входных переменных,
								   PSI - значение PSI.
	*/
	   
	*** Определение количества входных переменных;
	%let inputVarCnt=%SYSFUNC(countw(&inputVarList.,%STR('|')));
	
	*** Создание выходной таблицы;
	proc sql;
		create table OUTPUT_M_GET_PSI
		(
		factor character(50),
		PSI float format 9.2
		);
	quit;
	
	*** Цикл по всем переменным;
	%do varIdx=1 %to &inputVarCnt.;
		%let inputVar=%SCAN(%STR(&inputVarList.),&varIdx.,'|');
		
		*** Для каждого значения переменной рассчитывается его доля;
		proc sql noprint;
			select count(*)
			into: countVal
			from &rawdataset1.;
			
			select count(*)
			into: countDev
			from &rawdataset2.;
			
			create table VALIDATION_SET as
			select count(*) / &countVal. as ratio_val,
				&inputVar.
			from &rawDataSet1.
			group by &inputVar.;
			
			create table DEVELOPMENT_SET as
			select count(*) / &countDev. as ratio_dev,
				&inputVar.
			from &rawDataSet2.
			group by &inputVar.;
		quit;
		
		*** Промежуточные расчеты для PSI;
		data VARIABLE_SET;
			merge VALIDATION_SET DEVELOPMENT_SET;
			by &inputVar.;
			inter_PSI = (ratio_val - ratio_dev) * log(ratio_val / ratio_dev);
		run;
		
		proc sql noprint;
			insert into OUTPUT_M_GET_PSI (factor, PSI)
			select 
				"&inputVar." as factor,
				sum(inter_PSI) as PSI
			from VARIABLE_SET;
		quit;
		
		*** Удаление лишних наборов данных;
		proc datasets nolist;
			delete VALIDATION_SET DEVELOPMENT_SET VARIABLE_SET;
		run;
	%end;

%mend m_get_psi;


%macro m_population_stability_index(rawDataSet=, inputVarList=, periodVar=, periodLabelVar=, factorLabelSet=0, yellowThreshold=0.1, redThreshold=0.25);
	/* 
		Назначение: Производится расчет теста PSI для каждой переменной для всех периодов валидации.
	   
		Параметры:  rawDataSet      - Имя входного набора данных.
					inputVarList    - Строка, содержащая перечень имен входных переменных, разделитель - '|'.
								      Пример: variable1|variable2|variable3.
					periodVar       - Имя переменной, определяющей период.
							          Выборка для разработки - periodVar = 1,
								      выборки для валидации - последующие периоды (значения: 2, 3, 4 и т.д.).
					periodLabelVar  - Имя переменной, определяющей текстовую метку периода.
					factorLabelSet  - Набор данных, содержащий лейблы для факторов.
									  Должен содержать следующий набор полей:
											factor character			- название фактора,
											factor_label character		- лейбл фактора.
									  Значение по умолчанию = 0, в этом случае лейблы не используются.
					yellowThreshold - Желтое пороговое значение.
									  Значение по умолчанию = 0,1.
					redThreshold 	- Красное пороговое значение.
									  Значение по умолчанию = 0,25.
								  
		Вызываемые макросы:
					m_get_psi	 - Расчет PSI для одного периода валидации, выходная таблица - OUTPUT_M_GET_PSI.
	*/
				
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Определение количества входных переменных;
	%let inputVarCnt=%SYSFUNC(countw(&inputVarList.,%STR('|')));
	
	*** Определение периодов и текстовой метки периодов;
	proc sql noprint;
		create table PERIOD_LABEL as
		select distinct &periodVar., &periodLabelVar.
		from &rawDataSet.
		order by &periodVar.;
		
		select count(*)
		into :periodCnt
		from PERIOD_LABEL;
	quit;
	
	%let periodCnt = &periodCnt.;
		
	proc sql noprint;	
		select &periodVar., &periodLabelVar.
		into :period1-:period&periodCnt., :periodLabel1-:periodLabel&periodCnt.
		from PERIOD_LABEL;
	quit;
	
	*** Создание отдельного набора данных для каждого периода;
	%do periodNum = 1 %to &periodCnt.;
		data INPUT_&periodNum.;
			set &rawDataSet.;
			where &periodVar.=&&period&periodNum.;
		run;
	%end;
	
	*** Цикл по каждому периоду валидации;
	%do periodNum = 2 %to &periodCnt.;
	
		*** Создание таблицы OUTPUT_M_GET_PSI;
		%m_get_psi(rawDataSet1=INPUT_&periodNum., rawdataset2=INPUT_1, inputVarList=&inputVarList.);
		
		*** Переименование и сортировка наборов данных для последующего объединения в одну таблицу;
		data OUTPUT_M_GET_PSI_&periodNum.;
			set OUTPUT_M_GET_PSI;
			rename PSI=PSI_&periodNum.;
		run;
		
		proc sort data=OUTPUT_M_GET_PSI_&periodNum.;
			by factor;
		run;
		
		*** Удаление лишних наборов данных;
		proc datasets nolist;
			delete OUTPUT_M_GET_PSI INPUT_&periodNum.;
		run;
	%end;
	
	data REPORT_SET_PSI;
		merge
			%do periodNum = 2 %to &periodCnt.;
				OUTPUT_M_GET_PSI_&periodNum.
			%end;
		;
		by factor;
		format
			%do periodNum = 2 %to &periodCnt.;
				light_&periodNum.
			%end;
		$50.;
		%do periodNum = 2 %to &periodCnt.;
			select;
				when (PSI_&periodNum. > &redThreshold.)		light_&periodNum.="красный";
				when (PSI_&periodNum. > &yellowThreshold.)	light_&periodNum.="желтый";
				otherwise									light_&periodNum.="зеленый";
			end;
		%end;
	run;
	
	*** Выбор лейбла фактора;
	%if "&factorLabelSet." = "0" %then %do;
		data REPORT_SET_PSI_LABEL;
			set REPORT_SET_PSI;
			rename factor = factor_label;
		run;
	%end;
	%else %do;
		proc sql noprint;
			create table REPORT_SET_PSI_LABEL as
			select a.*,
				trim(a.factor) || ': ' || trim(b.factor_label) as factor_label
			from REPORT_SET_PSI as a
			left join &factorLabelSet. as b
				on upcase(a.factor) = upcase(b.factor);
		quit;
	%end;
	
	proc report data=REPORT_SET_PSI_LABEL SPLIT='';
		column factor_label
			%do periodNum = 2 %to &periodCnt.;
				PSI_&periodNum.	light_&periodNum.
			%end;
			;
		define factor_label / display "Фактор";
		%do periodNum = 2 %to &periodCnt.;
			define PSI_&periodNum. / display "PSI &&periodLabel&periodNum.";
			define light_&periodNum. / style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
									   display "Светофор &&periodLabel&periodNum.";
		%end;
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_1 PERIOD_LABEL REPORT_SET_PSI_LABEL
		%do periodNum = 2 %to &periodCnt.;
			OUTPUT_M_GET_PSI_&periodNum.
		%end;
		REPORT_SET_PSI;
	run;
	
%mend m_population_stability_index;


%macro m_score_distribution(rawValDataSet=, rawDevDataSet=, scaleVar=, c=4, titleNum=1);
	/* 
		Назначение: Строится график распределения скорингового балла по мастер-шкале,
					а также график плотности распределения.
	   
		Параметры:  rawValDataSet - Имя выборки для валидации.
					rawDevDataSet - Имя выборки для разработки.
					scaleVar	  - Имя переменной рейтинговой шкалы.
					c			  - Стандартизированная пропускная способность.
									Значение по умолчанию = 4.
					titleNum	  - Номер заголовка, необходимо к номеру заголовка перед вызовом макроса прибавить единицу.
									Значение по умолчанию = 1.
	*/
	
	*** Для каждого значения мастер-шкалы рассчитывается его доля; 
	proc sql noprint;
		select count(*)
		into :countVal
		from &rawValDataSet.;
		
		select count(*)
		into :countDev
		from &rawDevDataSet.;
		
		create table VALIDATION_SET as
		select count(*) / &countVal. as ratio_val format percent12.5,
			count(*) as cnt_val,
			&scaleVar. as grade
		from &rawValDataSet.
		group by grade;
		
		create table DEVELOPMENT_SET as
		select count(*) / &countDev. as ratio_dev format percent12.5,
			count(*) as cnt_dev,
			&scaleVar. as grade
		from &rawDevDataSet.
		group by grade;
	quit;
	
	proc sort data=VALIDATION_SET;
		by grade;
	run;
	
	proc sort data=DEVELOPMENT_SET;
		by grade;
	run;
	
	*** Объединение в один набор данных;
	data REPORT_SET;
		merge VALIDATION_SET DEVELOPMENT_SET;
		by grade;
		grade_num = _N_;
	run;
	
	Title2 h=12pt justify=left "Распределение скорингового балла по мастер-шкале на выборках для валидации и разработки";
	
	proc sgplot data=REPORT_SET;
		vbar grade / response=ratio_val
					 barwidth=0.8
					 legendlabel="Выборка для валидации";
		
		vbar grade / response=ratio_dev
					 barwidth=0.4
					 legendlabel="Выборка для разработки";
		
		xaxis display=(nolabel noline noticks);
		yaxis display=(nolabel noline noticks) grid;
	run;
	
	Title1;
	Title2 h=12pt justify=left "Плотность распределения скорингового балла по мастер-шкале на выборках для валидации и разработки";
	
	proc sgplot data=REPORT_SET;
		density grade_num / type=kernel(c=&c.)
							freq=cnt_val
							legendlabel="Выборка для валидации";
							
		density grade_num / type=kernel(c=&c.)
							freq=cnt_dev
							legendlabel="Выборка для разработки";
							
		xaxis display=none;
		yaxis display=(nolabel noline noticks) grid;
	run;
	
	Title1;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete REPORT_SET VALIDATION_SET DEVELOPMENT_SET;
	run;
	
%mend m_score_distribution;


%macro m_information_value(rawDataSet=, actualVar=, inputVarList=, periodVar=, periodLabelVar=, factorLabelSet=0, yellowThreshold=0.3, redThreshold=0.1);
	/* 
		Назначение: Для каждой переменной из inputVarList считается значение Information Value в разрезе периодов.
	   
		Параметры:  rawDataSet      - Имя входного набора данных.
					actualVar	    - Имя бинарной фактической переменной.
					inputVarList    - Строка, содержащая перечень имен входных переменных, разделитель - '|'.
								      Пример: variable1|variable2|variable3.
					periodVar       - Имя переменной, определяющей период.
							          Выборка для разработки - periodVar = 1,
								      выборки для валидации - последующие периоды (значения: 2, 3, 4 и т.д.).
					periodLabelVar  - Имя переменной, определяющей текстовую метку периода.
					factorLabelSet  - Набор данных, содержащий лейблы для факторов.
									  Должен содержать следующий набор полей:
											factor character			- название фактора,
											factor_label character		- лейбл фактора.
									  Значение по умолчанию = 0, в этом случае лейблы не используются.
					yellowThreshold - Желтое пороговое значение.
									  Значение по умолчанию = 0,3.
					redThreshold 	- Красное пороговое значение.
									  Значение по умолчанию = 0,1.
	*/
				
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Определение количества входных переменных;
	%let inputVarCnt=%SYSFUNC(countw(&inputVarList.,%STR('|')));
	
	*** Определение периодов и текстовой метки периодов;
	proc sql noprint;
		create table PERIOD_LABEL as
		select distinct &periodVar., &periodLabelVar.
		from &rawDataSet.
		order by &periodVar.;
		
		select count(*)
		into :periodCnt
		from PERIOD_LABEL;
	quit;
	
	%let periodCnt = &periodCnt.;
		
	proc sql noprint;	
		select &periodVar., &periodLabelVar.
		into :period1-:period&periodCnt., :periodLabel1-:periodLabel&periodCnt.
		from PERIOD_LABEL;
	quit;
	
	%do periodNum = 1 %to &periodCnt.;
		data DEFAULT_SET;
			set &rawDataSet.;
			where &periodVar.=&&period&periodNum. and &actualVar.=1;
		run;
		
		data NOT_DEFAULT_SET;
			set &rawDataSet.;
			where &periodVar.=&&period&periodNum. and &actualVar.=0;
		run;
		
		*** Создание таблицы OUTPUT_M_GET_PSI;
		%m_get_psi(rawDataSet1=DEFAULT_SET, rawdataset2=NOT_DEFAULT_SET, inputVarList=&inputVarList.);
		
		*** Переименование и сортировка наборов данных для последующего объединения в одну таблицу;
		data OUTPUT_M_GET_PSI_&periodNum.;
			set OUTPUT_M_GET_PSI;
			format light_&periodNum. $50.;
			select;
				when (PSI <= &redThreshold.) 	light_&periodNum.="красный";
				when (PSI <= &yellowThreshold.) light_&periodNum.="желтый";
				otherwise						light_&periodNum.="зеленый";
			end;
			rename PSI=IV_&periodNum.;
		run;
		
		proc sort data=OUTPUT_M_GET_PSI_&periodNum.;
			by factor;
		run;
		
		*** Удаление лишних наборов данных;
		proc datasets nolist;
			delete OUTPUT_M_GET_PSI DEFAULT_SET NOT_DEFAULT_SET;
		run;
	%end;
	
	*** Создание итогового набора;
	data REPORT_SET_IV;
		merge
			%do periodNum=1 %to &periodCnt.;
				OUTPUT_M_GET_PSI_&periodNum.
			%end;
		;
		by factor;
	run;
	
	*** Выбор лейбла фактора;
	%if "&factorLabelSet." = "0" %then %do;
		data REPORT_SET_IV_LABEL;
			set REPORT_SET_IV;
			rename factor = factor_label;
		run;
	%end;
	%else %do;
		proc sql noprint;
			create table REPORT_SET_IV_LABEL as
			select a.*,
				trim(a.factor) || ': ' || trim(b.factor_label) as factor_label
			from REPORT_SET_IV as a
			left join &factorLabelSet. as b
				on upcase(a.factor) = upcase(b.factor);
		quit;
	%end;
	
	proc report data=REPORT_SET_IV_LABEL SPLIT='';
		column factor_label
			%do periodNum = 1 %to &periodCnt.;
				IV_&periodNum.	light_&periodNum.
			%end;
			;
		define factor_label / display "Фактор";
		%do periodNum = 1 %to &periodCnt.;
			define IV_&periodNum. / display "Information Value &&periodLabel&periodNum.";
			define light_&periodNum. / style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
									   display "Светофор &&periodLabel&periodNum.";
		%end;
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete REPORT_SET_IV PERIOD_LABEL REPORT_SET_IV_LABEL
		%do periodNum=1 %to &periodCnt.;
			OUTPUT_M_GET_PSI_&periodNum.
		%end;
		;
	run;
	
%mend m_information_value;


%macro m_correlation_analysis(rawDataSet=, inputVarList=, factorLabelSet=0, redThreshold=0.5);
	/* 
		Назначение: Для переменных из inputVarList производится корреляционный анализ.
	   
		Параметры:  rawDataSet   	 - Имя входного набора данных.
					inputVarList 	 - Строка, содержащая перечень имен входных переменных, разделитель - '|'.
									   Пример: variable1|variable2|variable3.
					factorLabelSet	 - Набор данных, содержащий лейблы для факторов.
									   Должен содержать следующий набор полей:
											factor character			- название фактора,
											factor_label character		- лейбл фактора.
									   Значение по умолчанию = 0, в этом случае лейблы не используются.
					redThreshold 	 - Красное пороговое значение.
									   Значение по умолчанию = 0,5.
	*/
	
	*** Формат для определения цвета ячейки;
	proc format;
		value CORRCOLOR_FMT		-&redThreshold. - &redThreshold.="white"
															   1="cream"
															  -1="cream"
										  &redThreshold. - 0.999="salmon"
										-0.999 - -&redThreshold.="salmon";
	run;
	
	*** Определение количества входных переменных;
	%let inputVarCnt=%SYSFUNC(countw(&inputVarList.,%STR('|')));

	data VALIDATION_SET;
		set &rawDataSet. (keep=
							%do varIdx=1 %to &inputVarCnt.;
								%SCAN(%STR(&inputVarList.),&varIdx.,'|')
							%end;
						  );
	run;
	
	*** Корреляционный анализ, создание набора для отчета;
	proc corr data = VALIDATION_SET fisher outp=REPORT_SET noprint;
		var
			%do varIdx=1 %to &inputVarCnt.;
				%SCAN(%STR(&inputVarList.),&varIdx.,'|')
			%end;
			;
	run;
	
	data REPORT_SET(drop=_TYPE_ rename=(_NAME_=factor));
		set REPORT_SET;
		where _NAME_ is not missing;
		format
			%do varIdx=1 %to &inputVarCnt.;
				%SCAN(%STR(&inputVarList.),&varIdx.,'|')
			%end;
			percentn7.3;
		obs = _N_;
	run;
	
	*** Выбор лейбла фактора;
	%if "&factorLabelSet." = "0" %then %do;
		data REPORT_SET_LABEL;
			set REPORT_SET;
			rename factor = factor_label;
		run;
	%end;
	%else %do;
		proc sql noprint;
			create table REPORT_SET_LABEL as
			select a.*,
				trim(a.factor) || ': ' || trim(b.factor_label) as factor_label
			from REPORT_SET as a
			left join &factorLabelSet. as b
				on upcase(a.factor) = upcase(b.factor);
		quit;
	%end;
	
	proc sort data=REPORT_SET_LABEL;
		by obs;
	run;

	proc report data=REPORT_SET_LABEL SPLIT='';
		column obs factor_label
			%do varIdx=1 %to &inputVarcnt.;
				%SCAN(%STR(&inputVarList.),&varIdx.,'|')
			%end;
			;
		define obs / display "№";
		define factor_label /	display "Фактор"
								style(column)=[cellwidth=4in];
		%do varIdx=1 %to &inputVarcnt.;
			define %SCAN(%STR(&inputVarList.),&varIdx.,'|') / style(column)=[backgroundcolor=CORRCOLOR_FMT.]
															  display "&varIdx.";
		%end;
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete VALIDATION_SET REPORT_SET REPORT_SET_LABEL;
	run;
	
%mend m_correlation_analysis;


%macro m_variance_inflation_factor(rawDataSet=, actualVar=, InputVarList=, periodVar=, periodLabelVar=,
								   factorLabelSet=0, yellowThreshold=2, redThreshold=5);
	/* 
		Назначение: Для каждой переменной из inputVarList считается Variance inflation factor в разрезе периодов.
	   
		Параметры:  rawDataSet      - Имя входного набора данных.
					actualVar	    - Имя бинарной фактической переменной.
					inputVarList    - Строка, содержащая перечень имен входных переменных, разделитель - '|'.
								      Пример: variable1|variable2|variable3.
					periodVar       - Имя переменной, определяющей период.
							          Выборка для разработки - periodVar = 1,
								      выборки для валидации - последующие периоды (значения: 2, 3, 4 и т.д.).
					periodLabelVar  - Имя переменной, определяющей текстовую метку периода.
					factorLabelSet  - Набор данных, содержащий лейблы для факторов.
									  Должен содержать следующий набор полей:
											factor character			- название фактора,
											factor_label character		- лейбл фактора.
									  Значение по умолчанию = 0, в этом случае лейблы не используются.
					yellowThreshold - Желтое пороговое значение.
									  Значение по умолчанию = 2.
					redThreshold 	- Красное пороговое значение.
									  Значение по умолчанию = 5.
	*/
				
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Определение количества входных переменных;
	%let inputVarCnt=%SYSFUNC(countw(&inputVarList.,%STR('|')));
	
	data INPUT_VIF;
		set &rawDataSet.(keep= &actualVar. &periodVar. &periodLabelVar.
							%do varIdx=1 %to &inputVarCnt.;
								%SCAN(%STR(&inputVarList.),&varIdx.,'|')
							%end;
						);
	run;
	
	proc sort data = INPUT_VIF;
		by &periodVar.;
	run;
	
	*** Определение периодов и текстовой метки периодов;
	proc sql noprint;
		create table PERIOD_LABEL as
		select distinct &periodVar., &periodLabelVar.
		from INPUT_VIF
		order by &periodVar.;
		
		select count(*)
		into :periodCnt
		from PERIOD_LABEL;
	quit;
	
	%let periodCnt = &periodCnt.;
		
	proc sql noprint;	
		select &periodVar., &periodLabelVar.
		into :period1-:period&periodCnt., :periodLabel1-:periodLabel&periodCnt.
		from PERIOD_LABEL;
	quit;
	
	*** Расчет VIF;
	ods exclude all;

	proc reg data=INPUT_VIF;
		by &periodVar.;
		model &actualVar. =
			%do varIdx=1 %to &inputVarCnt.;
				%SCAN(%STR(&inputVarList.),&varIdx.,'|')
			%end; / vif;
		ods output ParameterEstimates = VIF_SET;
	run;
	
	ods exclude none;
	
	data VIF_SET;
		set VIF_SET(keep= &periodVar. Variable VarianceInflation);
		where Variable ^= 'Intercept';
		format light $50.;
		select;
			when (VarianceInflation > &redThreshold.)	 light="красный";
			when (VarianceInflation > &yellowThreshold.) light="желтый";
			otherwise 									 light="зеленый";
		end;
		rename Variable=factor VarianceInflation=VIF;
	run;
	
	proc sort data=VIF_SET;
		by &periodVar. factor;
	run;
	
	data REPORT_SET_VIF;
		merge
		%do periodNum=1 %to &periodCnt.;
			VIF_SET(where=(&periodVar.=&&period&periodNum.) rename=(VIF=VIF_&periodNum. light=light_&periodNum.))
		%end;
		;
		by factor;
		drop &periodVar.;
	run;
	
	*** Выбор лейбла фактора;
	%if "&factorLabelSet." = "0" %then %do;
		data REPORT_SET_VIF_LABEL;
			set REPORT_SET_VIF;
			rename factor = factor_label;
		run;
	%end;
	%else %do;
		proc sql noprint;
			create table REPORT_SET_VIF_LABEL as
			select a.*,
				trim(a.factor) || ': ' || trim(b.factor_label) as factor_label
			from REPORT_SET_VIF as a
			left join &factorLabelSet. as b
				on upcase(a.factor) = upcase(b.factor);
		quit;
	%end;
	
	proc report data=REPORT_SET_VIF_LABEL SPLIT='';
		column factor_label
			%do periodNum = 1 %to &periodCnt.;
				VIF_&periodNum. light_&periodNum.
			%end;
			;
		define factor_label / display "Фактор";
		%do periodNum = 1 %to &periodCnt.;
			define VIF_&periodNum. / display "VIF &&periodLabel&periodNum.";
			define light_&periodNum. / style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
									   display "Светофор &&periodLabel&periodNum.";
		%end;
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete REPORT_SET_VIF PERIOD_LABEL INPUT_VIF VIF_SET REPORT_SET_VIF_LABEL;
	run;
	
%mend m_variance_inflation_factor;


%macro m_herfindahl_index(rawDataSet=, scaleVar=, periodVar=, periodLabelVar=, yellowThreshold=0.2, redThreshold=0.3);
	/* 
		Назначение: Расчет индекса Херфиндаля для каждого периода валидации.
		
		Параметры:  rawDataSet      - Имя входного набора данных.
					scaleVar	    - Имя переменной рейтинговой шкалы.
					periodVar       - Имя переменной, определяющей период.
								      Выборка для разработки - periodVar = 1,
								      выборки для валидации - последующие периоды (значения: 2, 3, 4 и т.д.).
					periodLabelVar  - Имя переменной, определяющей текстовую метку периода.
					yellowThreshold - Желтое пороговое значение.
									  Значение по умолчанию = 0,2.
					redThreshold 	- Красное пороговое значение.
									  Значение по умолчанию = 0,3.
	*/
				
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Определение периодов и текстовой метки периодов;
	proc sql noprint;
		create table PERIOD_LABEL as
		select distinct &periodVar., &periodLabelVar.
		from &rawDataSet.
		order by &periodVar.;
		
		select count(*)
		into :periodCnt
		from PERIOD_LABEL;
	quit;
	
	%let periodCnt = &periodCnt.;
		
	proc sql noprint;	
		select &periodVar., &periodLabelVar.
		into :period1-:period&periodCnt., :periodLabel1-:periodLabel&periodCnt.
		from PERIOD_LABEL;
	quit;
	
	proc sql noprint;
		create table INPUT_GROUP as
		select &periodVar., &scaleVar., count(*) as count_num
		from &rawDataSet.
		group by &periodVar., &scaleVar.;
	quit;
	
	*** Цикл по периодам валидации;
	%do periodNum=1 %to &periodCnt.;
		proc sql noprint;
		
			*** Расчет доли и квадрата доли каждого значения шкалы;
			create table INPUT_&periodNum. as
			select &scaleVar., 
				count_num / sum(count_num) as percent,
				(calculated percent) * (calculated percent) as percent_square
			from INPUT_GROUP
			where &periodVar. = &&period&periodNum.;

			*** Расчет индекса Херфиндаля для текущего периода валидации;
			select sum(percent_square)
			into :herfindahl&periodNum.
			from INPUT_&periodNum.;
		quit;
	%end;
	
	*** Создание итогового набора;
	data REPORT_SET;
		format herfindahl percentn7.2 light $50.;
		%do periodNum=1 %to &periodCnt.;
			herfindahl = &&herfindahl&periodNum.;
			period_label = "&&periodLabel&periodNum.";
			select;
				when (herfindahl > &redThreshold.)	  light='красный';
				when (herfindahl > &yellowThreshold.) light='желтый';
				otherwise							  light='зеленый';
			end;
			output;
		%end;
	run;
	
	proc print data=REPORT_SET noobs label;
		var period_label herfindahl;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label   period_label = "Период"
				herfindahl="Индекс Херфиндаля"
				light="Светофор";
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete REPORT_SET INPUT_GROUP PERIOD_LABEL
		%do periodNum=1 %to &periodCnt.;
			INPUT_&periodNum.
		%end;
		;
	run;

%mend m_herfindahl_index;


%macro m_migration_analysis(keyVar=, rawValDataSet=, rawDevDataSet=, scaleVar=);
	/* 
		Назначение: Миграционнный анализ выборки для разработки и выборки для валидации.
	   
		Параметры:  keyVar		  - Имя ключевой переменной.
					a - Имя выборки для валидации.
					rawDevDataSet - Имя выборки для разработки.
					scaleVar	  - Имя переменной рейтинговой шкалы.
	*/
	
	*** Формат для определения цвета ячейки;
	proc format;
		value HEATMAP_FMT		0				= "TURQUOISE"
								0.00001 - 0.02	= "AQUAMARINE"
								0.02001 - 0.05	= "GREEN"
								0.05001 - 0.1	= "YELLOW"
								0.10001 - 0.15	= "ORANGE"
								0.15001 - 0.2	= "SALMON"
								0.20001 - 0.25	= "RED"
								0.25001 - 1		= "FIREBRICK";
	run;
	
	proc sql noprint;
		
		*** Создание таблицы с возможными значениями scaleVar;
		create table INPUT_SCALE as
		select distinct &scaleVar.
		from &rawDataSet.
		order by &scaleVar.;
		
		*** Количество сегментных переменных;
		select count(*)
		into :scaleNum
		from INPUT_SCALE;
	quit;
		
	%let scaleNum = &scaleNum.;
	
	proc sql noprint;
	
		*** Сохранение значений сегментных переменных;
		select &scaleVar.
		into: cat1-:cat&scaleNum.
		from INPUT_SCALE;
		
		*** Создание таблицы миграций клиентов;
		create table CLIENT_MIGRATIONS as
		select cur.&keyVar. as ID,
				cur.&scaleVar. as current_segment,
				dev.&scaleVar. as old_segment
		from &rawValDataSet. as cur
		left join &rawDevDataSet. as dev
			on cur.&keyVar. = dev.&keyVar;
		
		*** Группировка по старому и текущему сегментам;
		create table SEGMENT_MIGRATIONS_GROUP as
		select old_segment,
				current_segment,
				count(*) as migration_count
		from CLIENT_MIGRATIONS
		where old_segment is not missing
		group by old_segment, current_segment;
		
		*** Создание таблицы всех комбинаций пар старого и текущего сегментов;
		create table FULL_PAIRS as
		select a.&scaleVar. as old_segment,
				b.&scaleVar. as current_segment
		from INPUT_SCALE as a
		join INPUT_SCALE as b
			on 1=1;
		
		*** Создание полной таблицы с возможными null значениями, сгруппированной по сегментам;
		create table FULL_SEGMENT_MIGRATIONS_GROUP as
		select fp.old_segment,
				fp.current_segment,
				coalesce(smg.migration_count, 0) as migration_count
		from FULL_PAIRS as fp
		left join SEGMENT_MIGRATIONS_GROUP as smg
			on fp.old_segment = smg.old_segment
			and fp.current_segment = smg.current_segment;
		
		*** Расчет количества миграций, приходящихся на каждое значение старого сегмента;
		create table MIGRATION_COUNT_BY_CUR_PERIOD as
		select old_segment,
				sum(migration_count) as sum_migration_count
		from FULL_SEGMENT_MIGRATIONS_GROUP
		group  old_segment;
		
		*** Расчет относительного числа миграций для каждого значения старого сегмента;
		create table FULL_SEGM_MIGRATIONS_GROUP_PCT as
		select fs.current_segment,
				fs.old_segment,
				fs.migration_count / mc.sum_migration_count as migration_pct
		from FULL_SEGMENT_MIGRATIONS_GROUP as fs
		left join MIGRATION_COUNT_BY_CUR_PERIOD as mc
			on fs.old_segment = mc.old_segment
		order by fs.current_segment, fs.old_segment;
	quit;
		
	*** Создание квадратной таблицы миграций сегментов;
	proc transpose data=FULL_SEGM_MIGRATIONS_GROUP_PCT (keep=current_segment migration_pct) out=SEGMENT_MIGRATIONS;
		by current_segment;
	run;
	
	*** Форматирование и расчет процентов;
	data SEGMENT_MIGRATIONS (rename=(
								%do varIdx=1 %to &scaleNum.;
									col&varIdx. = &&cat&varIdx.
								%end;
								)
							);
		set SEGMENT_MIGRATIONS;
		format
			%do varIdx=1 %to &scaleNum.;
				col&varIdx.
			%end;
			percentn7.2;
		keep current_segment
			%do varIdx=1 %to &scaleNum.;
				col&varIdx.
			%end;
			;
	run;
	
	proc report data=SEGMENT_MIGRATIONS SPLIT='';
		column current_segment
			%do varIdx=1 %to &scaleNum.;
				&&cat&varIdx.
			%end;
			;
		define current_segment / display "Текущее значение сегмента";
		%do varIdx=1 %to &scaleNum.;
			define &&cat&varIdx. /  style(column)=[backgroundcolor=HEATMAP_FMT.]
									display "Из &&cat&varIdx.";
		%end;
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_SCALE CLIENT_MIGRATIONS SEGMENT_MIGRATIONS_GROUP MIGRATION_COUNT_BY_CUR_PERIOD
			   FULL_PAIRS FULL_SEGMENT_MIGRATIONS_GROUP SEGMENT_MIGRATIONS FULL_SEGM_MIGRATIONS_GROUP_PCT;
	run;
	
%mend m_migration_analysis;


%macro m_create_PD_validation_report(rawDataSet=, modelDesc=, keyVar=0, actualVar=, outputVar=, scoreVar=, segmentVar=, scaleVar=,
									 inputVarList=0, inputVarList_gr=0, periodVar=, periodLabelVar=,
									 factorBinLabelSet=, factorLabelSet=, thresholdSet=);
	/* 
		Назначение: Валидация модели PD.
	   
		Параметры:  rawDataSet		 - Имя входного набора данных.
					modelDesc		 - Описание модели.
					keyVar			 - Имя ключевой переменной.
									   Значение по умолчанию = 0. В этом случае анализ миграций не строится.
					actualVar		 - Имя бинарной фактической переменной.
					outputVar		 - Имя выходной переменной модели.
					scoreVar		 - Имя переменной, содержащей Скор-баллы.
					segmentVar		 - Имя переменной, разбивающей входной набор на сегменты.
					scaleVar		 - Имя подробной переменной рейтинговой шкалы.
					inputVarList	 - Строка, содержащая перечень имен переменных, разделитель - '|'.
									   Пример: variable1|variable2|variable3.
									   Значение по умолчанию = 0. В этом случае отчеты, использующие входные переменные, игнорируются.
					inputVarList_gr  - Строка, содержащая перечень имен групповых переменных, разделитель - '|'.
									   Пример: variable1|variable2|variable3.
									   Значение по умолчанию = 0. В этом случае отчеты, использующие входные групповые переменные, игнорируются.
					periodVar		 - Имя переменной, определяющей период.
									   Выборка для разработки - periodVar = 1,
									   выборки для валидации - последующие периоды (значения: 2, 3, 4 и т.д.).
					periodLabelVar	 - Имя переменной, определяющей текстовую метку периода.
					confLevelYellow	 - Желтый доверительный интервал.
					confLevelRed	 - Красный доверительный интервал.
					factorBinLabelSet- Набор данных, содержащий лейблы для значений бинов.
									   Должен содержать следующий набор полей:
											factor_gr character			- название фактора,
											bin_number integer			- номер бина,
											factor_gr_label character	- лейбл бина.
					factorLabelSet	 - Набор данных, содержащий лейблы для факторов.
									   Должен содержать следующий набор полей:
											factor character			- название фактора,
											factor_label character		- лейбл фактора.
					thresholdSet	 - Набор данных, содержащий пороговые значения.
									   Должен содержать следующий набор полей:
											macro_name character 		- название макроса,
											ordinal_number integer		- порядковый номер пороговых значений,
											yellow_threshold float		- желтое пороговое значение,
											red_threshold float			- красное пороговое значение,
											yellow_confidence_lvl		- желтый доверительный интервал,
											red_confidence_lvl			- красный доверительный интервал.
					
		Вызываемые макросы:
					m_information_table
					m_factor_information_table
					m_factor_distribution
					m_group_factor_distribution
					m_print_gini
					m_kolmogorov_smirnov
					m_information_value
					m_full_calibration_test
					m_population_stability_index
					m_score_distribution
					m_correlation_analysis
					m_variance_inflation_factor
					m_herfindahl_index
					m_migration_analysis
					
		Примечание: центральная тенденция определялась как avg(&outputVar.) на периоде валидации,
					сейчас определяется как avg(&actualVar.) на всем входном наборе,
					должна определяться экспертным мнением, передаваться как константа.
	*/
					   
	*** Определение значения периода валидации;
	proc sql noprint;
		select max(&periodVar.)
		into :valPeriod
		from &rawDataSet.;
	quit;
	
	*** Создание выборки для разработки;
	data __DEVELOPMENT_SET;
		set &rawDataSet.;
		where &periodVar. = 1;
	run;
	
	*** Создание выборки для валидации (последний месяц);
	data __VALIDATION_SET;
		set &rawDataSet.;
		where &periodVar. = &valPeriod.;
	run;
	
	*** Создание выборки для анализа репрезентативности;
	data __PORTFOLIO_SET;
		set &rawDataSet.;
		where &periodVar. = 0;
	run;
	
	proc sql noprint;
		select count(*)
		into :isPortfolio
		from __PORTFOLIO_SET;
	quit;
	
	*** Исключение выборки для анализа репрезентативности;
	data __WORK_SET;
		set &rawDataSet.;
		where &periodVar. > 0;
	run;
	
	*** Создание набора для всех периодов валидации;
	data __N_VALIDATIONS_SET;
		set &rawDataSet.;
		where &periodVar. > 1;
	run;
	
	***																		;
	*** Вычисление значения центральной тенденции							;
	*** Необходимо заменить этот шаг передачей значения в качестве константы;
	***																		;
	proc sql noprint;
		select avg(&actualVar.)
		into :__centralTrend
		from __WORK_SET;
	quit;
	
	Title1 h=26pt "Сводная информация";
	Title2 "Модель &modelDesc.";
	Title3 "Дата и время создания отчета: &sysdate9., &systime. &sysday.; пользователь: &sysuserid.";
	%m_information_table(rawDataSet=__WORK_SET, actualVar=&actualVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.);
	Title1;
	
	%if "&inputVarList." ^= "0" %then %do;
		Title1 h=26pt "1. Анализ качества данных";
		%m_factor_information_table(rawDataSet=__WORK_SET, inputVarList=&inputVarList., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
									factorLabelSet=&factorLabelSet.);
		Title1;
	%end;
	
		Title1 h=26pt "2. Предсказательная способность модели";
	%if "&inputVarList." ^= "0" %then %do;
		Title2 h=12pt justify=left "2.1. Распределение исходных факторов модели";
		%m_factor_distribution(rawValDataSet=__VALIDATION_SET, rawDevDataSet=__DEVELOPMENT_SET, inputVarList=&inputVarList., factorLabelSet=&factorLabelSet.);
		Title1;
	%end;
	
		%let y2label = Уровень дефолта;
		
		Title2 h=16pt justify=left "2.2. Уровень дефолта и концентрация наблюдений по категориям факторов";
	%if "&inputVarList_gr." ^= "0" %then %do;
		%m_group_factor_distribution(rawValDataSet=__VALIDATION_SET, rawDevDataSet=__DEVELOPMENT_SET, actualVar=&actualVar., inputVarList=&inputVarList_gr.,
									 factorBinLabelSet=&factorBinLabelSet., factorLabelSet=&factorLabelSet., y2label=&y2label.);
		Title1;
	%end;
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowModelThreshold, :redModelThreshold
		from &thresholdSet.
		where macro_name = 'm_print_gini' and ordinal_number = 1;
		
		select yellow_threshold, red_threshold
		into :yellowRelativeThreshold, :redRelativeThreshold
		from &thresholdSet.
		where macro_name = 'm_print_gini' and ordinal_number = 2;
		
		select yellow_threshold, red_threshold
		into :yellowFactorThreshold, :redFactorThreshold
		from &thresholdSet.
		where macro_name = 'm_print_gini' and ordinal_number = 3;
	quit;
	
	%if "&inputVarList_gr." ^= "0" %then %do;
		Title3 h=12pt justify=left "Расчет коэффициента Джини для факторов модели на выборках для разработки и валидации";
		Title4 h=12pt justify=left
		"Абсолютное значение. Желтая зона: %sysfunc(putn(&redFactorThreshold., percentn7.2)) - %sysfunc(putn(&yellowFactorThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redFactorThreshold., percentn7.2)).";
		Title5 h=12pt justify=left
		"Относительная разница. Желтая зона: %sysfunc(putn(&yellowRelativeThreshold., percentn7.2)) - %sysfunc(putn(&redRelativeThreshold., percentn7.2)), красная зона: >%sysfunc(putn(&redRelativeThreshold., percentn7.2)).";
		%m_print_gini(rawDataSet=__WORK_SET, actualVar=&actualVar., inputVarList=&inputVarList_gr.,
					  periodVar=&periodVar., periodLabelVar=&periodLabelVar., factorLabelSet=&factorLabelSet.,
					  yellowThreshold=&yellowFactorThreshold., redThreshold=&redFactorThreshold.,
					  yellowRelativeThreshold=&yellowRelativeThreshold., redRelativeThreshold=&redRelativeThreshold.,
					  titleNum=6);
		Title1;
	%end;
	
	Title3 h=12pt justify=left "Расчет коэффициента Джини на уровне модели на выборках для разработки и валидации на каждом сегменте";
	Title4 h=12pt justify=left
	"Абсолютное значение. Желтая зона: %sysfunc(putn(&redModelThreshold., percentn7.2)) - %sysfunc(putn(&yellowModelThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redModelThreshold., percentn7.2)).";
	Title5 h=12pt justify=left
	"Относительная разница. Желтая зона: %sysfunc(putn(&yellowRelativeThreshold., percentn7.2)) - %sysfunc(putn(&redRelativeThreshold., percentn7.2)), красная зона: >%sysfunc(putn(&redRelativeThreshold., percentn7.2)).";
	%m_print_gini(rawDataSet=__WORK_SET, actualVar=&actualVar., inputVarList=&outputVar., segmentVar=&segmentVar.,
				  periodVar=&periodVar., periodLabelVar=&periodLabelVar., factorLabelSet=&factorLabelSet., 
				  yellowThreshold=&yellowModelThreshold., redThreshold=&redModelThreshold.,
				  yellowRelativeThreshold=&yellowRelativeThreshold., redRelativeThreshold=&redRelativeThreshold.,
				  titleNum=6);
	
	*** Объединение набора для разработки и набора для валидации;
	data __ROC_SET;
		set __DEVELOPMENT_SET __VALIDATION_SET;
	run;
				  
	Title1 "ROC-кривая &outputVar. на выборках для разработки и валидации";
	%m_roc_curve(rawDataSet=__ROC_SET, inputVar=&outputVar., actualVar=&actualVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.);
	Title1;
	
	Title3 h=12pt justify=left "Расчет коэффициента Джини на уровне модели на выборках для разработки и валидации";
	Title4 h=12pt justify=left
	"Абсолютное значение. Желтая зона: %sysfunc(putn(&redModelThreshold., percentn7.2)) - %sysfunc(putn(&yellowModelThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redModelThreshold., percentn7.2)).";
	Title5 h=12pt justify=left
	"Относительная разница. Желтая зона: %sysfunc(putn(&yellowRelativeThreshold., percentn7.2)) - %sysfunc(putn(&redRelativeThreshold., percentn7.2)), красная зона: >%sysfunc(putn(&redRelativeThreshold., percentn7.2)).";
	%m_print_gini(rawDataSet=__WORK_SET, actualVar=&actualVar., inputVarList=&outputVar.,
				  periodVar=&periodVar., periodLabelVar=&periodLabelVar., factorLabelSet=&factorLabelSet.,
				  yellowThreshold=&yellowModelThreshold., redThreshold=&redModelThreshold.,
				  yellowRelativeThreshold=&yellowRelativeThreshold., redRelativeThreshold=&redRelativeThreshold.);
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_kolmogorov_smirnov';
	quit;
	
	Title2 h=12pt justify=left "2.4. Критерий согласия Колмогорова-Смирнова";
	%m_kolmogorov_smirnov(rawDataSet=__WORK_SET, scoreVar=&scoreVar., actualVar=&actualVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
						  yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	
	%if "&inputVarList_gr." ^= "0" %then %do;
		*** Выбор пороговых значений;	
		proc sql noprint;
			select yellow_threshold, red_threshold
			into :yellowThreshold, :redThreshold
			from &thresholdSet.
			where macro_name = 'm_information_value';
		quit;
		
		%let yellowThreshold = %sysfunc(putn(&yellowThreshold.,best18.));
		%let redThreshold = %sysfunc(putn(&redThreshold.,best18.));
		
		Title2 h=12pt justify=left "2.5. Тест значимости информации (Information Value)";
		Title3 h=12pt justify=left
		"Желтая зона: &redThreshold. - &yellowThreshold., красная зона: <= &redThreshold..";
		%m_information_value(rawDataSet=__N_VALIDATIONS_SET, actualVar=&actualVar.,
							 inputVarList=&inputVarList_gr., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
							 factorLabelSet=&factorLabelSet., yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
		Title1;
	%end;
	
	Title1 h=26pt "3. Калибровка";
	%m_full_calibration_test(rawDataSet=__VALIDATION_SET, outputVar=&outputVar., actualVar=&actualVar., scaleVar=&scaleVar.,
							 centralTrend=&__centralTrend., thresholdSet=&thresholdSet.);
	Title1;
	
	%if "&inputVarList_gr." ^= "0" %then %do;
		*** Выбор пороговых значений;	
		proc sql noprint;
			select yellow_threshold, red_threshold
			into :yellowThreshold, :redThreshold
			from &thresholdSet.
			where macro_name = 'm_population_stability_index';
		quit;
		
		%let yellowThreshold = %sysfunc(putn(&yellowThreshold.,best18.));
		%let redThreshold = %sysfunc(putn(&redThreshold.,best18.));
		
		*** Анализ репрезентативности производится, если предоставлены данные для портфолио;
		%if &isPortfolio. > 0 %then %do;
		
			data __REPRESENTATIVENESS;
				set __DEVELOPMENT_SET __PORTFOLIO_SET;
				if &periodVar. = 0 then &periodVar. = 2;
			run;
			
			Title1 h=26pt "4. Репрезентативность";
			Title2 h=12pt justify=left
			"Желтая зона: &yellowThreshold. - &redThreshold., красная зона: >&redThreshold..";
			%m_population_stability_index(rawDataSet=__REPRESENTATIVENESS, inputVarList=&inputVarList_gr., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
										  factorLabelSet=&factorLabelSet., yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
			Title1;
		%end;
		
	%end;
		
		Title1 h=26pt "5. Стабильность модели на уровне факторов";
	%if "&inputVarList_gr." ^= "0" %then %do;
		Title2 h=12pt justify=left "Результаты теста PSI";
		Title3 h=12pt justify=left
		"Желтая зона: &yellowThreshold. - &redThreshold., красная зона: >&redThreshold..";
		%m_population_stability_index(rawDataSet=__WORK_SET, inputVarList=&inputVarList_gr., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
									  factorLabelSet=&factorLabelSet., yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
		Title1;
	%end;
	
	%m_score_distribution(rawValDataSet=__VALIDATION_SET, rawDevDataSet=__DEVELOPMENT_SET, scaleVar=&scaleVar., titleNum=2);
	
	Title1 h=26pt "6. Дополнительные тесты";
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select red_threshold
		into :redThreshold
		from &thresholdSet.
		where macro_name = 'm_correlation_analysis';
	quit;
	
	%if "&inputVarList." ^= "0" %then %do;
		Title2 h=12pt justify=left "6.1. Корреляционный анализ факторов";
		Title3 h=12pt justify=left "Корреляционный анализ факторов модели";
		%m_correlation_analysis(rawDataSet=__VALIDATION_SET, inputVarList=&inputVarList., factorLabelSet=&factorLabelSet., redThreshold=&redThreshold.);
		Title1;
	%end;
	
	%if "&inputVarList_gr." ^= "0" %then %do;
		Title3 h=12pt justify=left "Корреляционный анализ сгруппированных факторов модели";
		%m_correlation_analysis(rawDataSet=__VALIDATION_SET, inputVarList=&inputVarList_gr., factorLabelSet=&factorLabelSet., redThreshold=&redThreshold.);
		Title1;
	%end;
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_variance_inflation_factor';
	quit;
	
	%let yellowThreshold = %sysfunc(putn(&yellowThreshold.,best18.));
	%let redThreshold = %sysfunc(putn(&redThreshold.,best18.));
	
	Title2 h=12pt justify=left "6.2. Фактор инфляции дисперсии, расчитанный на уровне модели";
	Title3 h=12pt justify=left
	"Желтая зона: &yellowThreshold. - &redThreshold., красная зона: >&redThreshold..";
	
	%if "&inputVarList." ^= "0" %then %do;
		Title4 h=12pt justify=left "Фактор инфляции дисперсии для факторов модели";
		
		%m_variance_inflation_factor(rawDataSet=__N_VALIDATIONS_SET, actualVar=&actualVar., inputVarList=&inputVarList.,
									 periodVar=&periodVar., periodLabelVar=&periodLabelVar., factorLabelSet=&factorLabelSet.,
									 yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
		Title1;
	%end;
	
	%if "&inputVarList_gr." ^= "0" %then %do;
		Title4 h=12pt justify=left "Фактор инфляции дисперсии для сгруппированных факторов модели";
		%m_variance_inflation_factor(rawDataSet=__N_VALIDATIONS_SET, actualVar=&actualVar., inputVarList=&inputVarList_gr.,
									 periodVar=&periodVar., periodLabelVar=&periodLabelVar., factorLabelSet=&factorLabelSet.,
									 yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
		Title1;
	%end;
	
	*** Выбор пороговых значений;	
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_herfindahl_index';
	quit;
	
	Title2 h=12pt justify=left "6.3. Индекс Херфиндаля";
	Title3 h=12pt justify=left
	"Желтая зона: %sysfunc(putn(&redThreshold., percentn7.2)) - %sysfunc(putn(&yellowThreshold., percentn7.2)), красная зона: >%sysfunc(putn(&redThreshold., percentn7.2)).";
	%m_herfindahl_index(rawDataSet=__N_VALIDATIONS_SET, scaleVar=&scaleVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
						yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	Title1;
	
	*** В качестве набора для валидации используется набор портфолио, если он существует;
	%if &isPortfolio. > 0 %then %do;
		%let migrationSet = __PORTFOLIO_SET;
	%end;
	%else %do;
		%let migrationSet = __VALIDATION_SET;
	%end;
	
	%if "&keyVar." ^= "0" %then %do;
		Title2 h=12pt justify=left "6.4. Анализ миграций";
		%m_migration_analysis(keyVar=&keyVar., rawValDataSet=&migrationSet., rawDevDataSet=__VALIDATION_SET, scaleVar=&scaleVar.);
		Title1;
	%end;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete __DEVELOPMENT_SET __VALIDATION_SET __PORTFOLIO_SET __WORK_SET __REPRESENTATIVENESS __N_VALIDATIONS_SET __ROC_SET;
	run;
	
	ods _all_ close;
	
%mend m_create_PD_validation_report;


%macro m_information_table_LGD(rawDataSet=, actualVar=, periodVar=, periodLabelVar=);
	/* 
		Назначение: Вывод информации о количестве наблюдений и среднем значении LGD в разрезе периодов.
	   
		Параметры:  rawDataSet     - Имя входного набора данных.
					actualVar	   - Имя фактической переменной.
					periodVar	   - Имя переменной, определяющей период.
					periodLabelVar - Имя переменной, определяющей текстовую метку периода.
	*/

	proc sql;
		create table REPORT_SET as
		select &periodLabelVar.,
			&periodVar.,
			count(*) as observations_count,
			avg(&actualVar.) as average_LGD format 7.2
		from &rawDataSet.
		group by &periodLabelVar., &periodVar.
		order by &periodVar.;
	quit;
		
	proc print data=REPORT_SET noobs label;
		var &periodLabelVar. observations_count average_LGD;
		label   &periodLabelVar.="Период"
				observations_count="Число наблюдений"
				average_LGD="Среднее значение LGD"; 
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete REPORT_SET;
	run;

%mend m_information_table_LGD;


%macro m_get_simple_modif_gini(rawDataSet=, outputVar=0, actualVar=, actualVarEAD=0, inputVarList=);
	/* 
		Назначение: Расчет коэффициента Джини для каждой переменной из inputVarList.
	   
		Параметры:  rawDataSet	 - Имя входного набора.
					outputVar	 - Имя выходной переменной модели.
								   Значение по умолчанию = 0.
				    actualVar	 - Имя фактической переменной LGD.
					actualVarEAD - Имя фактической переменной EAD.
								   Значение по умолчанию = 0.
				    inputVarList - Строка, содержащая перечень имен переменных, разделитель - '|'.
								   Пример: variable1|variable2|variable3.
									
		Выходная таблица:		 - OUTPUT_M_GET_SIMPLE_MODIF_GINI
								   (
									variable1 float,
									variable2 float,
									variable3 float,
									...
								   )
								   Выходная таблица содержит одну строку:
								   значение коэффициента Джини для каждой переменной из inputVarList.
								   
		Результат работы:
					Если указаны outputVar и actualVarEAD, а также outputVar входит в список переменных inputVarList,
						то Джини для outputVar будет рассчитан со взвешиванием на EAD.
					Иначе все переменные из inputVarList считаются без взвешивания.
	*/
	   
	*** Определение количества входных переменных;
	%let inputVarCnt=%SYSFUNC(countw(&inputVarList.,%STR('|')));
	
	*** Копирование исходного набора, чтобы избежать изменений;
	data INPUT_SET;
		set &rawDataSet.;
		where &actualVar. ^= .;
	run;
	
	*** Цикл по входным переменным;
	%do varIdx=1 %to &inputVarCnt.;
		%let inputVar=%SCAN(%STR(&inputVarList.),&varIdx.,'|');
		
		*** Для выходной переменной модели рассчет производится с взвешиванием на EAD;
		%if "&inputVar." = "&outputVar." %then %do;
			data INPUT_SIMPLE (keep= &inputVar. &actualVar. &actualVarEAD. loss);
				set INPUT_SET;
				where &inputVar. ^= . and &actualVarEAD. ^= .;
				loss = &actualVar. * &actualVarEAD.;
			run;
			
			%let giniVar = loss;
			%let weightVar = &actualVarEAD.;
		%end;
		%else %do;
			data INPUT_SIMPLE (keep= &inputVar. &actualVar. const_one);
				set INPUT_SET;
				where &inputVar. ^= .;
				const_one = 1;
			run;
			
			%let giniVar = &actualVar.;
			%let weightVar = const_one;
		%end;
		
		*** Расчет сумм весовой переменной и переменной Джини;
		proc sql noprint;
			select
				sum(&weightVar.),sum(&giniVar.)
			into :sumWeightVar, :sumGiniVar
			from INPUT_SIMPLE;
		quit;
		
		*** Расчет значения идеальной прощади areaIdeal;
		proc sort data=INPUT_SIMPLE out=SORT_BY_ACTUAL_VAR (keep=&giniVar. &weightVar.);
			by descending &actualVar.;
		run;
		
		data SORT_BY_ACTUAL_VAR (keep=cumulative_gini_var_pct cumulative_gini_var_pct_lag &weightVar.);
			set SORT_BY_ACTUAL_VAR;
			retain cumulative_gini_var_pct;
			cumulative_gini_var_pct + &giniVar. / &sumGiniVar.;
			cumulative_gini_var_pct_lag = lag1(cumulative_gini_var_pct);
		run;
		
		proc sql noprint;
			select sum(0.5 * (cumulative_gini_var_pct + cumulative_gini_var_pct_lag) * &weightVar.) / &sumWeightVar. - 0.5
			into :areaIdeal_&varIdx.
			from SORT_BY_ACTUAL_VAR;
		quit;
		
		*** Расчет площади для переменной;
		proc sort data=INPUT_SIMPLE out=SORT_BY_INPUT_VAR (keep=&giniVar. &weightVar.);
			by descending &inputVar.;
		run;

		data SORT_BY_INPUT_VAR (keep=cumulative_gini_var_pct cumulative_gini_var_pct_lag &weightVar.);
			set SORT_BY_INPUT_VAR;
			retain cumulative_gini_var_pct;
			cumulative_gini_var_pct + &giniVar. / &sumGiniVar.;
			cumulative_gini_var_pct_lag = lag1(cumulative_gini_var_pct);
		run;

		proc sql noprint;
			select sum(0.5 * (cumulative_gini_var_pct + cumulative_gini_var_pct_lag) * &weightVar.) / &sumWeightVar. - 0.5
			into :area_&varIdx.
			from SORT_BY_INPUT_VAR;
		quit;	
	%end;
	
	*** Создание итогового набора данных;
	data OUTPUT_M_GET_SIMPLE_MODIF_GINI;
		%do varIdx=1 %to &inputVarCnt.;
			%SCAN(%STR(&inputVarList.),&varIdx.,'|') = &&area_&varIdx. / &&areaIdeal_&varIdx.;
		%end;
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_SET SORT_BY_ACTUAL_VAR SORT_BY_INPUT_VAR INPUT_SIMPLE;
	run;

%mend m_get_simple_modif_gini;


%macro m_print_modif_gini(rawValDataSet=, rawDevDataSet=, outputVar=, actualVar=, actualVarEAD=0, inputVarList=0,
						  factorLabelSet=0, yellowFactorThreshold=0.1, redFactorThreshold=0.05, yellowModelThreshold=0.3, redModelThreshold=0.15,
						  yellowRelativeThreshold=0.05, redRelativeThreshold=0.1);
	/* 
		Назначение: Расчет модифицированного коэффициента Джини для входных переменных в разрезе периодов,
					расчет модифицированного коэффициента Джини для выходной переменной в разрезе периодов.
	   
		Параметры:  rawValDataSet   - Имя выборки для валидации.
					rawDevDataSet   - Имя выборки для разработки.
					outputVar	    - Имя выходной переменной модели.
					actualVar		- Имя фактической переменной LGD.
					actualVarEAD	- Имя фактической переменной EAD.
									  Значение по умолчанию = 0.
									  При нуле, взвешивание выходной переменной на EAD не производится.
					inputVarList    - Строка, содержащая перечень имен входных переменных, разделитель - '|'.
								      Пример: variable1|variable2|variable3.
									  Значение по умолчанию = 0. В этом случае Джини считается только для выходной переменной.
					factorLabelSet	- Набор данных, содержащий лейблы для факторов.
									  Должен содержать следующий набор полей:
											factor character			- название фактора,
											factor_label character		- лейбл фактора.
									  Значение по умолчанию = 0, в этом случае лейблы не используются.
					yellowFactorThreshold	- Желтое пороговое значение для факторов.
											  Значение по умолчанию = 0,1.
					redFactorThreshold		- Красное пороговое значение для факторов.
											  Значение по умолчанию = 0,05.
					yellowModelThreshold	- Желтое пороговое значение для модели.
											  Значение по умолчанию = 0,3.
					redModelThreshold		- Красное пороговое значение для модели.
											  Значение по умолчанию = 0,15.
					yellowRelativeThreshold - Относительное желтое пороговое значение.
											  Значение по умолчанию = 0,05.
					redRelativeThreshold	- Относительное красное пороговое значение.
											  Значение по умолчанию = 0,1.
								   
		Вызываемые макросы:
					m_get_simple_modif_gini	 - Расчет модифицированного коэффициента Джини для одного периода,
											   выходная таблица - OUTPUT_M_GET_SIMPLE_MODIF_GINI.
											   
		Результат работы:
					Если указана переменная actualVarEAD, то outputVar взвешивается на EAD.
					Если указана переменная inputVarList, то сначала выводится результат для каждой переменной из списка,
						а затем отдельная таблица для outputVar.
	*/
	
	*** Количество итераций при расчете модифицированного коэффициента Джини;
	%let iterationNum = 10;
	
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	%if "&inputVarList." = "0" %then %do;
		%let sumVarList = &outputVar.;
	%end;
	%else %do;
		%let sumVarList = &inputVarList.|&outputVar.;
	%end;
	
	*** Определение количества входных переменных;
	%let sumVarCnt=%SYSFUNC(countw(&sumVarList.,%STR('|')));
	
	%if "&actualVarEAD." = "0" %then %do;
		%let keepVars = &actualVar.;
		%let simpleGiniInputVars = actualVar=&actualVar., inputVarList=&sumVarList.;
	%end;
	%else %do;
		%let keepVars = &actualVar. &actualVarEAD.;
		%let simpleGiniInputVars = outputVar=&outputVar., actualVar=&actualVar., actualVarEAD=&actualVarEAD., inputVarList=&sumVarList.;
	%end;
	
	*** Копирование исходного набора, чтобы избежать изменений;
	data INPUT_1;
		set &rawDevDataSet. (keep= &keepVars.
							%do varIdx=1 %to &sumVarCnt.;
								%SCAN(%STR(&sumVarList.),&varIdx.,'|')
							%end;
							);
	run;
	
	data INPUT_2;
		set &rawValDataSet. (keep= &keepVars.
							%do varIdx=1 %to &sumVarCnt.;
								%SCAN(%STR(&sumVarList.),&varIdx.,'|')
							%end;
							);
	run;
	
	*** Цикл по периодам;
	%do idx=1 %to 2;
		
		*** Расчет модифицированного коэффициента Джини;
		%m_get_simple_modif_gini(rawDataSet=INPUT_&idx., &simpleGiniInputVars.);
		
		proc transpose data=OUTPUT_M_GET_SIMPLE_MODIF_GINI
						out=GINI_VALUE;
		run;
		
		*** Создание таблицы для хранения результатов итераций;
		proc sql;
			create table RESULT_ITERATION 
			(
				%do varIdx=1 %to &sumVarCnt.;
					%SCAN(%STR(&sumVarList.), &varIdx.,'|') float format percentn7.2
					%if &varIdx. < &sumVarCnt. %then
						,
					;
				%end;
			);
		quit;
		
		*** Цикл для расчета доверительных интервалов модифицированного коэффициента Джини;
		%do iterIdx=1 %to &iterationNum.;
		
			*** Создание случайной выборки (с равной вероятностью и с повторениями), размер как у исходного набора;
			proc surveyselect data=INPUT_&idx.
								method=urs
								samprate=1
								outhits
								out=SAMPLE_SET noprint;
			run;
			
			*** Расчет модифицированного коэффициента Джини для одной итерации;
			%m_get_simple_modif_gini(rawDataSet=SAMPLE_SET, &simpleGiniInputVars.);
			
			*** Вставка в таблицу RESULT_ITERATION;
			proc sql;
				insert into RESULT_ITERATION
				(
					%do varIdx=1 %to &sumVarCnt.;
						%SCAN(%STR(&sumVarList.), &varIdx.,'|')
						%if &varIdx. < &sumVarCnt. %then
							,
						;
					%end;
				)
				select
					%do varIdx=1 %to &sumVarCnt.;
						%SCAN(%STR(&sumVarList.), &varIdx.,'|')
						%if &varIdx. < &sumVarCnt. %then
							,
						;
					%end;
				from OUTPUT_M_GET_SIMPLE_MODIF_GINI; 
			quit;
			
			*** Удаление лишних наборов данных;
			proc datasets nolist;
				delete SAMPLE_SET OUTPUT_M_GET_SIMPLE_MODIF_GINI;
			run;
		%end;
		
		*** Расчет 5-го и 95-го процентилей для каждой переменной;
		proc stdize data=RESULT_ITERATION
					PctlMtd=ord_stat
					outstat=GINI_CONFIDENCE_LEVELS
					out=DATA1
					pctlpts=5, 95;
			var
				%do varIdx=1 %to &sumVarCnt.;
					%SCAN(%STR(&sumVarList.),&varIdx.,'|')
				%end;
				;
		run;
		
		data GINI_CONFIDENCE_LEVELS;
			set GINI_CONFIDENCE_LEVELS;
			where _type_ =: 'P';
		run;
		
		proc sort data=GINI_CONFIDENCE_LEVELS;
			by _type_;
		run;
		
		proc transpose data=GINI_CONFIDENCE_LEVELS
						out=GINI_CONFIDENCE_LEVELS;
		run;
		
		*** Создание итоговой таблицы для периода;
		proc sql;
			create table GINI_BY_FACTOR_&idx. as
			select conf._NAME_ as factor,
				conf.Col1 as gini_lower format percentn7.2,
				gini.Col1 as gini_value format percentn7.2,
				conf.Col2 as gini_upper format percentn7.2
			from GINI_CONFIDENCE_LEVELS as conf
			inner join GINI_VALUE as gini
				on conf._NAME_ = gini._NAME_;
		quit;
	%end;
	
	*** Создание итоговой таблицы;
	proc sql;
		create table OUTPUT_M_GET_MODIF_GINI as
		select dev.factor,
			dev.gini_value as gini_dev,
			dev.gini_lower as gini_lower_dev,
			dev.gini_upper as gini_upper_dev,
			val.gini_value as gini_val,
			val.gini_lower as gini_lower_val,
			val.gini_upper as gini_upper_val,
			(val.gini_value - dev.gini_value) / dev.gini_value as diff format percentn7.2,
			case when abs(calculated diff) > &redRelativeThreshold. then "красный"
				when abs(calculated diff) > &yellowRelativeThreshold. then "желтый"
				else "зеленый" end as light_rel
		from GINI_BY_FACTOR_1 as dev
		inner join GINI_BY_FACTOR_2 as val
			on dev.factor=val.factor;
	quit;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete DATA1 GINI_VALUE GINI_CONFIDENCE_LEVELS RESULT_ITERATION
			%do idx=1 %to 2;
				INPUT_&idx. GINI_BY_FACTOR_&idx.
			%end;
			;
	run;
	
	
	***																										  ;
	*** Расчет модифицированного коэффициента Джини для факторов модели на выборках для разработки и валидации;
	***																										  ;
	
	%if "&inputVarList." ^= "0" %then %do;
		data GINI_INPUT_VARS;
			set OUTPUT_M_GET_MODIF_GINI;
			where factor ^= "&outputVar.";
			format light_dev light_val $30.;
			
			old_gini_lower_dev = gini_lower_dev;
			old_gini_upper_dev = gini_upper_dev;
			if gini_dev < 0 then do;
				gini_dev = abs(gini_dev);
				gini_lower_dev = -1 * old_gini_upper_dev;
				gini_upper_dev = -1 * old_gini_lower_dev;
			end;
			select;
				when (gini_lower_dev < &redFactorThreshold.)	light_dev = "красный";
				when (gini_lower_dev < &yellowFactorThreshold.) light_dev = "желтый";
				otherwise										light_dev = "зеленый";
			end;
			
			old_gini_lower_val = gini_lower_val;
			old_gini_upper_val = gini_upper_val;
			if gini_val < 0 then do;
				gini_val = abs(gini_val);
				gini_lower_val = -1 * old_gini_upper_val;
				gini_upper_val = -1 * old_gini_lower_val;
			end;
			select;
				when (gini_lower_val < &redFactorThreshold.)	light_val = "красный";
				when (gini_lower_val < &yellowFactorThreshold.) light_val = "желтый";
				otherwise										light_val = "зеленый";
			end;
		run;
		
		*** Выбор лейбла фактора;
		%if "&factorLabelSet." = "0" %then %do;
			data REPORT_SET_GINI_INPUT;
				set GINI_INPUT_VARS;
				rename factor = factor_label;
			run;
		%end;
		%else %do;
			proc sql noprint;
				create table REPORT_SET_GINI_INPUT as
				select a.*,
					trim(a.factor) || ': ' || trim(b.factor_label) as factor_label
				from GINI_INPUT_VARS as a
				left join &factorLabelSet. as b
					on upcase(a.factor) = upcase(b.factor);
			quit;
		%end;
	
		Title3 h=12pt justify=left "Расчет модифицированного коэффициента Джини для факторов модели на выборках для разработки и валидации";
		Title4 h=12pt justify=left
		"Абсолютное значение. Желтая зона: %sysfunc(putn(&redFactorThreshold., percentn7.2)) - %sysfunc(putn(&yellowFactorThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redFactorThreshold., percentn7.2)).";
		Title5 h=12pt justify=left
		"Относительная разница. Желтая зона: %sysfunc(putn(&yellowRelativeThreshold., percentn7.2)) - %sysfunc(putn(&redRelativeThreshold., percentn7.2)), красная зона: >%sysfunc(putn(&redRelativeThreshold., percentn7.2)).";
		Title6 h=12pt "Выборка для разработки";
		
		proc report data=REPORT_SET_GINI_INPUT SPLIT='';
			column factor_label gini_dev gini_lower_dev gini_upper_dev light_dev;
			define factor_label /	display "Фактор"
									style(column)=[fontsize=1]
									style(header)=[fontsize=1];
			define gini_dev /	display "Джини"
								style(header)=[fontsize=1];
			define gini_lower_dev / display "Нижняя граница"
									style(header)=[fontsize=1];
			define gini_upper_dev / display "Верхняя граница"
									style(header)=[fontsize=1];
			define light_dev /	display "Светофор"
								style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
								style(header)=[fontsize=1];
		run;
		
		Title1;
		
		Title6 h=12pt "Выборка для валидации";
		
		proc report data=REPORT_SET_GINI_INPUT SPLIT='';
			column factor_label gini_val gini_lower_val gini_upper_val light_val diff light_rel;
			define factor_label /	display "Фактор"
									style(column)=[fontsize=1]
									style(header)=[fontsize=1];
			define gini_val /	display "Джини"
								style(header)=[fontsize=1];
			define gini_lower_val / display "Нижняя граница"
									style(header)=[fontsize=1];
			define gini_upper_val / display "Верхняя граница"
									style(header)=[fontsize=1];
			define light_val /	display "Светофор, абсолютное значение"
								style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
								style(header)=[fontsize=1];
			define diff /	display "Относительная разница(%)"
							style(header)=[fontsize=1];
			define light_rel /	display "Светофор, относительная разница"
								style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
								style(header)=[fontsize=1];
		run;
		
		Title1;
	%end;
	
	
	***																									   ;
	*** Расчет модифицированного коэффициента Джини на уровне модели на выборках для разработки и валидации;
	***																									   ;
	
	data REPORT_SET_GINI_OUTPUT;
		set OUTPUT_M_GET_MODIF_GINI;
		where factor = "&outputVar.";
		format light_dev light_val $30.;
		select;
			when (gini_lower_dev < &redModelThreshold.)	   light_dev = "красный";
			when (gini_lower_dev < &yellowModelThreshold.) light_dev = "желтый";
			otherwise									   light_dev = "зеленый";
		end;
		
		select;
			when (gini_lower_val < &redModelThreshold.)	   light_val = "красный";
			when (gini_lower_val < &yellowModelThreshold.) light_val = "желтый";
			otherwise									   light_val = "зеленый";
		end;
	run;
	
	Title3 h=12pt justify=left "Расчет модифицированного коэффициента Джини на уровне модели на выборках для разработки и валидации";
	Title4 h=12pt justify=left
	"Абсолютное значение. Желтая зона: %sysfunc(putn(&redModelThreshold., percentn7.2)) - %sysfunc(putn(&yellowModelThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redModelThreshold., percentn7.2)).";
	Title5 h=12pt justify=left
	"Относительная разница. Желтая зона: %sysfunc(putn(&yellowRelativeThreshold., percentn7.2)) - %sysfunc(putn(&redRelativeThreshold., percentn7.2)), красная зона: >%sysfunc(putn(&redRelativeThreshold., percentn7.2)).";
	
	proc print data= REPORT_SET_GINI_OUTPUT noobs label;
		var gini_dev gini_lower_dev gini_upper_dev;
		var light_dev / style(data)=[background=$BACKCOLOR_FMT.];
		var gini_val gini_lower_val gini_upper_val;
		var light_val / style(data)=[background=$BACKCOLOR_FMT.];
		var diff;
		var light_rel / style(data)=[background=$BACKCOLOR_FMT.];
		label   gini_dev="Джини, разработка"
				gini_lower_dev="Нижняя граница, разработка"
				gini_upper_dev="Верхняя граница, разработка"
				light_dev="Светофор, разработка"
				gini_val="Джини, валидация"
				gini_lower_val="Нижняя граница, валидация"
				gini_upper_val="Верхняя граница, валидация"
				light_val="Светофор, валидация"
				diff="Относительная разница(%)"
				light_rel="Светофор, относительная разница";
	run;
	
	Title1;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete GINI_INPUT_VARS GINI_OUTPUT_VAR OUTPUT_M_GET_MODIF_GINI REPORT_SET_GINI_OUTPUT REPORT_SET_GINI_INPUT;
	run;

%mend m_print_modif_gini;


%macro m_spearmans_correlation(rawDataSet=, outputVar=, actualVar=, periodVar=, periodLabelVar=, yellowThreshold=0.5, redThreshold=0.25);
	/* 
		Назначение: Расчет значения корреляции Спирмена в разрезе периодов.
		
		Параметры:  rawDataSet      - Имя входного набора данных.
					outputVar	    - Имя выходной переменной модели.
					actualVar	    - Имя фактической переменной.
					periodVar       - Имя переменной, определяющей период.
					periodLabelVar  - Имя переменной, определяющей текстовую метку периода.
					yellowThreshold - Желтое пороговое значение.
									  Значение по умолчанию = 0,5.
					redThreshold 	- Красное пороговое значение.
									  Значение по умолчанию = 0,25.
	*/
	
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Копирование исходного набора, чтобы избежать изменений;
	data INPUT_VALIDATION;
		set &rawDataSet. (keep= &actualVar. &outputVar. &periodVar. &periodLabelVar.);
	run;
	
	*** Сортирока по периодам;
	proc sort data=INPUT_VALIDATION;
		by &periodVar.;
	run;
	
	*** Вычисление корреляции Спирмена в разрезе периодов;
	ods exclude all;
	
	proc corr spearman data=INPUT_VALIDATION
					   fisher(biasadj=no type=twosided);
		by &periodVar. &periodLabelVar.;
		var &actualVar. &outputVar.;
		ods output FisherSpearmanCorr=RESULT_SET_SPEARMAN (keep= &periodLabelVar. Lcl Corr Ucl);
	run;
	
	ods exclude none;

	data RESULT_SET_SPEARMAN;
		set RESULT_SET_SPEARMAN;
		format light $30. Lcl Corr Ucl Percentn7.2;
		select;
			when (Lcl < &redThreshold.)	   light = "красный";
			when (Lcl < &yellowThreshold.) light = "желтый";
			otherwise 					   light = "зеленый";
		end;
		rename Lcl=lower_bound_95 Ucl=upper_bound_95 Corr = spearman_corr;
	run;
	
	*** Вывод результатов;
	proc print data=RESULT_SET_SPEARMAN noobs label;
		var &periodLabelVar. lower_bound_95 spearman_corr upper_bound_95;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label	&periodLabelVar. = "Период валидации"
				lower_bound_95 = "Нижняя граница"
				spearman_corr = "Корреляция Спирмена"
				upper_bound_95 = "Верхняя граница"
				light = "Светофор";
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_VALIDATION TECH_PERIOD_LABEL RESULT_SET_SPEARMAN;
	run;
	
%mend m_spearmans_correlation;


%macro m_r_squared(rawDataSet=, actualVar=, outputVar=, periodVar=, periodLabelVar=, yellowThreshold=0.5, redThreshold=0.25);
	/* 
		Назначение: Расчет значения коэффициента детерминации (R^2) в разрезе периодов.
		
		Параметры:  rawDataSet      - Имя входного набора данных.
					outputVar	    - Имя выходной переменной модели.
					actualVar	    - Имя фактической переменной.
					periodVar       - Имя переменной, определяющей период.
					periodLabelVar  - Имя переменной, определяющей текстовую метку периода.
					yellowThreshold - Желтое пороговое значение.
									  Значение по умолчанию = 0,5.
					redThreshold 	- Красное пороговое значение.
									  Значение по умолчанию = 0,25.
	*/
	
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Копирование исходного набора, чтобы избежать изменений;
	data INPUT_SET;
		set &rawDataSet. (keep= &actualVar. &outputVar. &periodVar. &periodLabelVar.);
		where &outputVar. ^= . and &actualVar. ^= .;
	run;
	
	*** Определение периодов и текстовой метки периодов;
	proc sql noprint;
		create table PERIOD_LABEL as
		select distinct &periodVar., &periodLabelVar.
		from INPUT_SET
		order by &periodVar.;
		
		select count(*)
		into :periodCnt
		from PERIOD_LABEL;
	quit;
	
	%let periodCnt = &periodCnt.;
		
	proc sql noprint;	
		select &periodVar., &periodLabelVar.
		into :period1-:period&periodCnt., :periodLabel1-:periodLabel&periodCnt.
		from PERIOD_LABEL;
	quit;
	
	*** Цикл по периодам валидации, расчет R^2;
	%do periodNum=1 %to &periodCnt.;
		proc sql noprint;
			select avg(&actualVar.)
			into :avgActualVar
			from INPUT_SET
			where &periodVar.=&&period&periodNum.;
			
			select sum((&actualVar. - &outputVar.) ** 2),
					sum((&actualVar. - &avgActualVar.) ** 2),
					max(&periodLabelVar.)
			into :RSS,
					:TSS,
					:labelValue
			from INPUT_SET
			where &periodVar.=&&period&periodNum.;
		quit;
		
		data R2_&periodNum.;
			format R2 percentn7.2 light $30.;
			R2 = 1 - &RSS. / &TSS.;
			&periodLabelVar. = "&labelValue.";
			select;
				when (R2 < &redThreshold.)	  light = "красный";
				when (R2 < &yellowThreshold.) light = "желтый";
				otherwise					  light = "зеленый";
			end;
		run;
	%end;
	
	*** Объединение наборов в один;
	data RESULT_SET_R2;
		set
		%do periodNum=1 %to &periodCnt.;
			R2_&periodNum.
		%end;
		;
	run;
	
	*** Вывод результатов;
	proc print data=RESULT_SET_R2 noobs label;
		var &periodLabelVar. R2;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label	&periodLabelVar. = "Период валидации"
				R2 = "Значение R2"
				light = "Светофор";
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_SET RESULT_SET_R2 PERIOD_LABEL
			%do periodNum=1 %to &periodCnt.;
				R2_&periodNum.
			%end;
			;
	run;
	
%mend m_r_squared;


%macro m_root_mean_square_err(rawDataSet=, outputVar=, actualVar=, periodVar=, periodLabelVar=, yellowThreshold=0.1, redThreshold=0.2);
	/* 
		Назначение: Расчет значения корня из суммы квадратов ошибки (RMSE) в разрезе периодов.
		
		Параметры:  rawDataSet      - Имя входного набора данных.
					outputVar	    - Имя выходной переменной модели.
					actualVar	    - Имя фактической переменной.
					periodVar       - Имя переменной, определяющей период.
					periodLabelVar  - Имя переменной, определяющей текстовую метку периода.
					yellowThreshold - Желтое пороговое значение.
									  Значение по умолчанию = 0,1.
					redThreshold 	- Красное пороговое значение.
									  Значение по умолчанию = 0,2.
	*/
	
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Удаление периода разработки;
	data INPUT_VALIDATION;
		set &rawDataSet. (keep= &actualVar. &outputVar. &periodVar. &periodLabelVar.);
		where &outputVar. ^= . and &actualVar. ^= .;
	run;
	
	*** Расчет RMSE в разрезе периодов;
	proc sql noprint;
		create table RESULT_SET_RMSE as
		select
			&periodVar.,
			&periodLabelVar.,
			sqrt(sum((&actualVar. - &outputVar.) ** 2) / (count(*) - 1)) / avg(&actualVar.) as RMSE
		from INPUT_VALIDATION
		group by &periodVar., &periodLabelVar.
		order by &periodVar.;
	quit;
		
	data RESULT_SET_RMSE;
		set RESULT_SET_RMSE;
		format RMSE percentn7.2 light $30.;
		select;
			when (RMSE > &redThreshold.)	light = "красный";
			when (RMSE > &yellowThreshold.) light = "желтый";
			otherwise						light = "зеленый";
		end;
	run;
	
	*** Вывод результатов;
	proc print data=RESULT_SET_RMSE noobs label;
		var &periodLabelVar. RMSE;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label	&periodLabelVar. = "Период валидации"
				RMSE = "Значение RMSE"
				light = "Светофор";
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_VALIDATION RESULT_SET_RMSE;
	run;

%mend m_root_mean_square_err;


%macro m_loss_shortfall(rawDataSet=, outputVar=, actualVar=, actualVarEAD=, periodVar=, periodLabelVar=, yellowThreshold=0.1, redThreshold=0.2);
	/* 
		Назначение: Расчет коэффициента Loss Shortfall в разрезе периодов.
		
		Параметры:  rawDataSet      - Имя входного набора данных.
					outputVar	    - Имя выходной переменной модели.
					actualVar	    - Имя фактической переменной.
					actualVarEAD    - Имя фактической переменной EAD.
					periodVar       - Имя переменной, определяющей период.
					periodLabelVar  - Имя переменной, определяющей текстовую метку периода.
					yellowThreshold - Желтое пороговое значение.
									  Значение по умолчанию = 0,1.
					redThreshold 	- Красное пороговое значение.
									  Значение по умолчанию = 0,2.
	*/
	
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Удаление периода разработки, расчет потерь;
	data INPUT_VALIDATION;
		set &rawDataSet.;
		where &outputVar. ^= . and &actualVar. ^= .;
		loss_predicted = &outputVar. * &actualVarEAD.;
		loss_actual = &actualVar. * &actualVarEAD.;
		keep &periodVar. &periodLabelVar. loss_predicted loss_actual;
	run;
	
	*** Расчет коэффициента Loss Shortfall;
	proc sql noprint;
		create table RESULT_SET_LSH as
		select &periodVar.,
				&periodLabelVar.,
				sum(loss_predicted) as summ_loss_predicted,
				sum(loss_actual) as summ_loss_actual
		from INPUT_VALIDATION
		group by &periodVar., &periodLabelVar.
		order by &periodVar.;
	quit;
	
	data RESULT_SET_LSH;
		set RESULT_SET_LSH;
		format loss_shortfall 9.2 light $30.;
		loss_shortfall = 1 - (summ_loss_predicted / summ_loss_actual);
		select;
			when (abs(loss_shortfall) > &redThreshold.)	   light = "красный";
			when (abs(loss_shortfall) > &yellowThreshold.) light = "желтый";
			otherwise									   light = "зеленый";
		end;
	run;
	
	*** Вывод результатов;
	proc print data=RESULT_SET_LSH noobs label;
		var &periodLabelVar. loss_shortfall;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label	&periodLabelVar. = "Период валидации"
				loss_shortfall = "Loss Shortfall"
				light = "Светофор";
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_VALIDATION RESULT_SET_LSH;
	run;

%mend m_loss_shortfall;


%macro m_t_test(rawDataSet=, outputVar=, actualVar=, periodVar=, periodLabelVar=);
	/* 
		Назначение: Расчет T-теста в разрезе периодов.
		
		Параметры:  rawDataSet     - Имя входного набора данных.
					outputVar	   - Имя выходной переменной модели.
					actualVar	   - Имя фактической переменной.
					periodVar      - Имя переменной, определяющей период.
					periodLabelVar - Имя переменной, определяющей текстовую метку периода.
	*/
	
	data INPUT_SET;
		set &rawDataSet. (keep = &outputVar. &actualVar. &periodVar. &periodLabelVar.);
		where &outputVar. ^= . and &actualVar. ^= .;
	run;
	
	*** Создание набора с фактической переменной;
	data INPUT_ACTUAL;
		set INPUT_SET (keep = &actualVar. &periodVar. &periodLabelVar.);
		rename &actualVar. = observed_var;
		sample = 'actual';
	run;
	
	*** Создание набора с модельной переменной;
	data INPUT_MODEL;
		set INPUT_SET (keep = &outputVar. &periodVar. &periodLabelVar.);
		rename &outputVar. = observed_var;
		sample = 'model';
	run;
	
	*** Объединение наборов и сортировка;
	data VALIDATION_SET;
		set INPUT_ACTUAL INPUT_MODEL;
	run;
	
	proc sort data= VALIDATION_SET;
		by &periodVar. sample;
	run;
	
	*** Выполнение T-теста;
	ods exclude all;
	
	proc ttest data=VALIDATION_SET;
		by &periodVar. &periodLabelVar.;
		class sample;
		var observed_var;
		ods output equality=RESULT_SET_F_STAT ttests=RESULT_SET_T_TEST;
	run;
		
	ods exclude none;
	
	Title3 "Результаты T-теста";
	
	*** Вывод Результатов;
	proc print data=RESULT_SET_F_STAT noobs label;
		var &periodLabelVar. numdf Fvalue ProbF;
		label	&periodLabelVar. = "Период валидации"
				numdf = "Количество степеней свободы"
				Fvalue = "Значение F-статистики"
				Probf = "P-Value";
	run;
	
	Title1;
	
	proc print data=RESULT_SET_T_TEST noobs label;
		var &periodLabelVar. variances tValue Probt;
		label	&periodLabelVar. = "Период валидации"
				variances = "Метод"
				tValue = "Значение статистики"
				Probt = "P-Value";
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_SET INPUT_ACTUAL INPUT_MODEL VALIDATION_SET RESULT_SET_F_STAT RESULT_SET_T_TEST;
	run;

%mend m_t_test;


%macro m_mann_whitney(rawDataSet=, inputVarList=, periodVar=, periodLabelVar=, factorLabelSet=0, yellowThreshold=0.1, redThreshold=0.05);
	/* 
		Назначение: Расчет U-статистики Манна-Уитни для каждой переменной из inputVarList
					в разрезе периодов валидации.
		
		Параметры:  rawDataSet       - Имя входного набора данных.
					inputVarList     - Строка, содержащая перечень имен переменных, разделитель - '|'.
								       Пример: variable1|variable2|variable3.
					periodVar        - Имя переменной, определяющей период.
								       Выборка для разработки - periodVar = 1,
								       выборки для валидации - последующие периоды (значения: 2, 3, 4 и т.д.).
					periodLabelVar   - Имя переменной, определяющей текстовую метку периода.
					factorLabelSet	 - Набор данных, содержащий лейблы для факторов.
									   Должен содержать следующий набор полей:
											factor character			- название фактора,
											factor_label character		- лейбл фактора.
									   Значение по умолчанию = 0, в этом случае лейблы не используются.
					yellowThreshold  - Желтое пороговое значение.
									   Значение по умолчанию = 0,15.
					redThreshold 	 - Красное пороговое значение.
									   Значение по умолчанию = 0,01.
	*/
	
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Создание списка входных переменных, перечисленных через пробел;
	%let inputVarSpaceList = %SYSFUNC(tranwrd(&inputVarList.,|,));
	
	*** Определение количества входных переменных;
	%let inputVarCnt=%SYSFUNC(countw(&inputVarList.,%STR('|')));
	
	*** Определение периодов и текстовой метки периодов;
	proc sql noprint;
		create table PERIOD_LABEL as
		select distinct &periodVar., &periodLabelVar.
		from &rawDataSet.
		order by &periodVar.;
		
		select count(*)
		into :periodCnt
		from PERIOD_LABEL;
	quit;
	
	%let periodCnt = &periodCnt.;
		
	proc sql noprint;	
		select &periodVar., &periodLabelVar.
		into :period1-:period&periodCnt., :periodLabel1-:periodLabel&periodCnt.
		from PERIOD_LABEL;
	quit;
	
	*** Разеделение исходного набора по периодам;
	%do periodNum = 1 %to &periodCnt.;
		data INPUT_&periodNum.;
			set &rawDataSet.;
			where &periodVar.=&&period&periodNum.;
			sample = "&periodNum.";
			keep &inputVarSpaceList. sample;
		run;
	%end;
	
	*** Цикл по периодам валидации;
	%do periodNum=2 %to &periodCnt.;

		*** Объединение выборки для разработки и текущей выборки для валидации, и расчет U-статистики Манна-Уитни;
		data INPUT_&periodNum.;
			set INPUT_&periodNum. INPUT_1;
		run;
	
		ods exclude all;
		
		proc npar1way data=INPUT_&periodNum. wilcoxon;
			class sample;
			var &inputVarSpaceList.;
			ods output WilcoxonTest=OUT_WILCOXON;
		run;
	
		ods exclude none;
		
		*** Остается только название переменной и ее Z-Score;
		data OUT_WILCOXON_ZSCORE (keep= factor zScore_&periodNum.);
			set OUT_WILCOXON;
			where name1 = 'Z_WIL';
			format nValue1 9.2;
			rename nValue1=zScore_&periodNum. variable=factor;
		run;
		
		proc sort data= OUT_WILCOXON_ZSCORE;
			by factor;
		run;
		
		*** Остается только название переменной и ее P-Value;
		data OUT_WILCOXON_PVALUE (keep= factor pValue_&periodNum. light_&periodNum.);
			set OUT_WILCOXON;
			format pValue_&periodNum. percentn7.2;
			where name1 = 'P2_WIL';
			pValue_&periodNum. = nValue1;
			select;
				when (pValue_&periodNum. < &redThreshold.)		light_&periodNum.='красный';
				when (pValue_&periodNum. < &yellowThreshold.)	light_&periodNum.='желтый';
				otherwise										light_&periodNum.='зеленый';
			end;
			rename variable=factor;
		run;
		
		proc sort data= OUT_WILCOXON_PVALUE;
			by factor;
		run;
		
		*** Конкатенация Z-Score и P-Value;
		data REPORT_SET_&periodNum.;
			merge OUT_WILCOXON_ZSCORE OUT_WILCOXON_PVALUE;
			by factor;
		run;
		
	%end;
	
	*** Если число переменных больше одной, то в строках переменные, месяцы растянуты по столбцам.
	*** Если переменная одна, то в строках месяцы.
	%if &inputVarCnt. > 1 %then %do;
	
		*** Объединение периодов;
		data REPORT_SET_UMANN;
			merge
			%do periodNum = 2 %to &periodCnt.;
				REPORT_SET_&periodNum.
			%end;
			;
			by factor;
		run;
		
		*** Выбор лейбла фактора;
		%if "&factorLabelSet." = "0" %then %do;
			data REPORT_SET_UMANN_LABEL;
				set REPORT_SET_UMANN;
				rename factor = factor_label;
			run;
		%end;
		%else %do;
			proc sql noprint;
				create table REPORT_SET_UMANN_LABEL as
				select a.*,
					trim(a.factor) || ': ' || trim(b.factor_label) as factor_label
				from REPORT_SET_UMANN as a
				left join &factorLabelSet. as b
					on upcase(a.factor) = upcase(b.factor);
			quit;
		%end;
		
		*** Вывод результатов;
		proc report data=REPORT_SET_UMANN_LABEL SPLIT='';
			column factor_label
				%do periodNum = 2 %to &periodCnt.;
					zScore_&periodNum. pValue_&periodNum. light_&periodNum.
				%end;
				;
			define factor_label /	display "Фактор"
									style(header)=[fontsize=1];
			%do periodNum = 2 %to &periodCnt.;
				define zScore_&periodNum. / display "Z-Score &&periodLabel&periodNum."
											style(header)=[fontsize=1];
				define pValue_&periodNum. / display "P-Value &&periodLabel&periodNum."
											style(header)=[fontsize=1];
				define light_&periodNum. /	display "Светофор"
											style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
											style(header)=[fontsize=1];
			%end;
		run;
	%end;
	%else %do;
	
		*** Добавление месяца и переименование переменных;
		%do periodNum = 2 %to &periodCnt.;
			data REPORT_SET_&periodNum. (keep= period period_label zScore pValue light);
				length period_label $50.;
				set REPORT_SET_&periodNum.;
				period = &&period&periodNum.;
				period_label = "&&periodLabel&periodNum.";
				rename zScore_&periodNum. = zScore pValue_&periodNum. = pValue light_&periodNum. = light;
			run;
		%end;
		
		*** Объединение периодов и сортировка по периоду;
		data REPORT_SET_UMANN;
			set
			%do periodNum = 2 %to &periodCnt.;
				REPORT_SET_&periodNum.
			%end;
			;
		run;
		
		proc sort data=REPORT_SET_UMANN;
			by period;
		run;
		
		*** Вывод результатов;
		proc report data=REPORT_SET_UMANN SPLIT='';
			column period_label zScore pValue light;
			define period_label /	display "Период"
									style(header)=[fontsize=1];
			define zScore / display "Z-Score"
							style(header)=[fontsize=1];
			define pValue / display "P-Value"
							style(header)=[fontsize=1];
			define light /	display "Светофор"
							style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
							style(header)=[fontsize=1];
		run;
	%end;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete PERIOD_LABEL OUT_WILCOXON OUT_WILCOXON_ZSCORE OUT_WILCOXON_PVALUE REPORT_SET_UMANN REPORT_SET_UMANN_LABEL
		%do periodNum = 1 %to &periodCnt.;
			INPUT_&periodNum.
			REPORT_SET_&periodNum.
		%end;
		;
	run;

%mend m_mann_whitney;


%macro m_create_LGD_validation_report(rawDataSet=, modelDesc=, outputVar=, actualVarLGD=, actualVarEAD=, inputVarList=0, inputVarList_gr=0,
									  subModelVar=0, periodVar=, periodLabelVar=, factorBinLabelSet=, factorLabelSet=, thresholdSet=);
	/* 
		Назначение: Валидация модели LGD.
	   
		Параметры:  rawDataSet		 - Имя входного набора данных.
					modelDesc		 - Описание модели.
					outputVar		 - Имя выходной переменной модели.
					actualVarLGD	 - Имя фактической переменной LGD.
					actualVarEAD	 - Имя фактической переменной EAD.
					inputVarList	 - Строка, содержащая перечень имен переменных, разделитель - '|'.
									   Пример: variable1|variable2|variable3.
									   Значение по умолчанию = 0. В этом случае отчеты, использующие входные переменные, игнорируются.
					inputVarList_gr  - Строка, содержащая перечень имен групповых переменных, разделитель - '|'.
									   Пример: variable1|variable2|variable3.
									   Значение по умолчанию = 0. В этом случае отчеты, использующие входные групповые переменные, игнорируются.
					subModelVar		 - Строка, содержащая перечень имен итоговых переменных подмоделей, разделитель - '|'.
									   Пример: variable1|variable2|variable3.
									   Значение по умолчанию = 0. В этом случае отчеты, использующие подмодельные переменные, игнорируются.
					periodVar		 - Имя переменной, определяющей период.
									   Выборка для разработки - periodVar = 1,
									   выборки для валидации - последующие периоды (значения: 2, 3, 4 и т.д.).
					periodLabelVar	 - Имя переменной, определяющей текстовую метку периода.
					factorBinLabelSet- Набор данных, содержащий лейблы для значений бинов.
									   Должен содержать следующий набор полей:
											factor_gr character			- название фактора,
											bin_number integer			- номер бина,
											factor_gr_label character	- лейбл бина.
					factorLabelSet	 - Набор данных, содержащий лейблы для факторов.
									   Должен содержать следующий набор полей:
											factor character			- название фактора,
											factor_label character		- лейбл фактора.
					thresholdSet	 - Набор данных, содержащий пороговые значения.
									   Должен содержать следующий набор полей:
											macro_name character 		- название макроса,
											ordinal_number integer		- порядковый номер пороговых значений,
											yellow_threshold float		- желтое пороговое значение,
											red_threshold float			- красное пороговое значение.
					
		Вызываемые макросы:
					m_information_table_LGD
					m_factor_information_table
					m_factor_distribution
					m_group_factor_distribution
					m_print_modif_gini
					m_roc_curve
					m_spearmans_correlation
					m_r_squared
					m_root_mean_square_err
					m_loss_shortfall
					m_t_test
					m_mann_whitney
					m_population_stability_index
	*/
	
	*** Определение значения периода валидации;
	proc sql noprint;
		select max(&periodVar.)
		into :valPeriod
		from &rawDataSet.;
	quit;
	
	*** Создание выборки для разработки;
	data __DEVELOPMENT_SET;
		set &rawDataSet.;
		where &periodVar. = 1;
	run;
	
	*** Создание выборки для валидации;
	data __VALIDATION_SET;
		set &rawDataSet.;
		where &periodVar. = &valPeriod.;
	run;
	
	*** Создание выборки для анализа репрезентативности;
	data __PORTFOLIO_SET;
		set &rawDataSet.;
		where &periodVar. = 0;
	run;
	
	proc sql noprint;
		select count(*)
		into :isPortfolio
		from __PORTFOLIO_SET;
	quit;
	
	*** Исключение выборки для анализа репрезентативности;
	data __WORK_SET;
		set &rawDataSet.;
		where &periodVar. > 0;
	run;
	
	*** Создание набора для всех периодов валидации;
	data __N_VALIDATIONS_SET;
		set &rawDataSet.;
		where &periodVar. > 1;
	run;
	
	Title1 h=26pt "Сводная информация";
	Title2 "Модель &modelDesc.";
	Title3 "Дата и время создания отчета: &sysdate9., &systime. &sysday.; пользователь: &sysuserid.";
	%m_information_table_LGD(rawDataSet=__WORK_SET, actualVar=&actualVarLGD., periodVar=&periodVar., periodLabelVar=&periodLabelVar.);
	
	%if "&inputVarList." ^= "0" %then %do;
		Title1 h=26pt "1. Анализ качества данных";
		Title2 h=12pt justify=left "1.1. Сводная информация по факторам модели";
		%m_factor_information_table(rawDataSet=__WORK_SET, inputVarList=&inputVarList., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
									factorLabelSet=&factorLabelSet.);
	
	
		Title2 h=12pt justify=left "1.2. Распределение значений факторов";	
		%m_factor_distribution(rawValDataSet=__VALIDATION_SET, rawDevDataSet=__DEVELOPMENT_SET, inputVarList=&inputVarList., factorLabelSet=&factorLabelSet.);
		Title1;
	%end;
	
	%let y2label = Среднее значение LGD;
	
		Title1 h=26pt "2. Предсказательная способность модели";
	%if "&inputVarList_gr." ^= "0" %then %do;
		Title2 h=12pt justify=left "2.1. Анализ чувствительности риск-факторов";
		%m_group_factor_distribution(rawValDataSet=__VALIDATION_SET, rawDevDataSet=__DEVELOPMENT_SET, actualVar=&actualVarLGD., inputVarList=&inputVarList_gr.,
									 factorBinLabelSet=&factorBinLabelSet., factorLabelSet=&factorLabelSet., y2label=&y2label.);
		Title1;
	%end;
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowModelThreshold, :redModelThreshold
		from &thresholdSet.
		where macro_name = 'm_print_modif_gini' and ordinal_number = 1;
		
		select yellow_threshold, red_threshold
		into :yellowRelativeThreshold, :redRelativeThreshold
		from &thresholdSet.
		where macro_name = 'm_print_modif_gini' and ordinal_number = 2;
		
		select yellow_threshold, red_threshold
		into :yellowFactorThreshold, :redFactorThreshold
		from &thresholdSet.
		where macro_name = 'm_print_modif_gini' and ordinal_number = 3;
	quit;
	
	Title2 h=12pt justify=left "2.2. Значение предсказательной способности";
	%m_print_modif_gini(rawValDataSet=__VALIDATION_SET, rawDevDataSet=__DEVELOPMENT_SET, outputVar=&outputVar., actualVar=&actualVarLGD.,
						actualVarEAD=&actualVarEAD., inputVarList=&inputVarList_gr., factorLabelSet=&factorLabelSet.,
						yellowFactorThreshold=&yellowFactorThreshold., redFactorThreshold=&redFactorThreshold.,
						yellowModelThreshold=&yellowModelThreshold., redModelThreshold=&redModelThreshold.,
						yellowRelativeThreshold=&yellowRelativeThreshold., redRelativeThreshold=&redRelativeThreshold.);
	Title1;
	
	*** Объединение набора для разработки и набора для валидации;
	data __ROC_SET;
		set __DEVELOPMENT_SET __VALIDATION_SET;
	run;
				  
	Title1 "ROC-кривая &outputVar. на выборках для разработки и валидации";
	%m_roc_curve(rawDataSet=__ROC_SET, inputVar=&outputVar., actualVar=&actualVarLGD., periodVar=&periodVar., periodLabelVar=&periodLabelVar.);
	Title1;
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_spearmans_correlation';
	quit;
	
	Title2 h=12pt justify=left "2.3. Корреляция Спирмена";
	Title3 h=12pt justify=left
	"Желтая зона: %sysfunc(putn(&redThreshold., percentn7.2)) - %sysfunc(putn(&yellowThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redThreshold., percentn7.2)).";
	%m_spearmans_correlation(rawDataSet=__N_VALIDATIONS_SET, outputVar=&outputVar., actualVar=&actualVarLGD.,
							 periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
							 yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	Title1;
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_r_squared';
	quit;
	
	Title1 h=26pt "3. Калибровка";
	Title2 h=12pt justify=left "3.1. Коэффициент детерминации";
	Title3 h=12pt justify=left
	"Желтая зона: %sysfunc(putn(&redThreshold., percentn7.2)) - %sysfunc(putn(&yellowThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redThreshold., percentn7.2)).";
	%m_r_squared(rawDataSet=__N_VALIDATIONS_SET, actualVar=&actualVarLGD., outputVar=&outputVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
				 yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	Title1;
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_root_mean_square_err';
	quit;
	
	Title2 h=12pt justify=left "3.2. Среднеквадратичная ошибка";
	Title3 h=12pt justify=left
	"Желтая зона: %sysfunc(putn(&yellowThreshold., percentn7.2)) - %sysfunc(putn(&redThreshold., percentn7.2)), красная зона: >%sysfunc(putn(&redThreshold., percentn7.2)).";
	%m_root_mean_square_err(rawDataSet=__N_VALIDATIONS_SET, outputVar=&outputVar., actualVar=&actualVarLGD.,
							periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
							yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_loss_shortfall';
	quit;
	
	%let yellowThreshold = %sysfunc(putn(&yellowThreshold.,best18.));
	%let redThreshold = %sysfunc(putn(&redThreshold.,best18.));
	
	Title2 h=12pt justify=left "3.3. Коэффициент LossShortfall";
	Title3 h=12pt justify=left
	"Желтая зона: &yellowThreshold. - &redThreshold., красная зона: >&redThreshold., значения берутся по модулю.";
	%m_loss_shortfall(rawDataSet=__N_VALIDATIONS_SET, outputVar=&outputVar., actualVar=&actualVarLGD., 
					  actualVarEAD=&actualVarEAD., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
					  yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	
	Title2 h=12pt justify=left "3.4. T-тест / U-статистика Манна-Уитни";
	%m_t_test(rawDataSet=__N_VALIDATIONS_SET, outputVar=&outputVar., actualVar=&actualVarLGD., periodVar=&periodVar., periodLabelVar=&periodLabelVar.);
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_mann_whitney'
			and ordinal_number = 1;
	quit;
	
	Title3 "Результаты U-статистики Манна-Уитни";
	Title4 h=12pt justify=left
	"Желтая зона: %sysfunc(putn(&redThreshold., percentn7.2)) - %sysfunc(putn(&yellowThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redThreshold., percentn7.2)).";
	Title5 h=12pt justify=left "&outputVar.";
	%m_mann_whitney(rawDataSet=__WORK_SET, inputVarList=&outputVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
					yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	
	%if "&inputVarList_gr." ^= "0" %then %do;
		*** Выбор пороговых значений;	
		proc sql noprint;
			select yellow_threshold, red_threshold
			into :yellowThreshold, :redThreshold
			from &thresholdSet.
			where macro_name = 'm_population_stability_index';
		quit;
		
		%let yellowThreshold = %sysfunc(putn(&yellowThreshold.,best18.));
		%let redThreshold = %sysfunc(putn(&redThreshold.,best18.));
		
		*** Анализ репрезентативности производится, если предоставлены данные для портфолио;
		%if &isPortfolio. > 0 %then %do;
		
			data __REPRESENTATIVENESS;
				set __DEVELOPMENT_SET __PORTFOLIO_SET;
				if &periodVar. = 0 then &periodVar. = 2;
			run;
		
			Title1 h=26pt "4. Репрезентативность";
			Title2 h=12pt justify=left
			"Желтая зона: &yellowThreshold. - &redThreshold., красная зона: >&redThreshold..";
			%m_population_stability_index(rawDataSet=__REPRESENTATIVENESS, inputVarList=&inputVarList_gr., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
										  factorLabelSet=&factorLabelSet., yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
			Title1;
		%end;
	%end;
	
		Title1 h=26pt "5. Стабильность";
	%if "&inputVarList." ^= "0" %then %do;
		Title2 h=12pt justify=left "5.1. Результаты Теста PSI для исходных модельных факторов";
		Title3 h=12pt justify=left
		"Желтая зона: &yellowThreshold. - &redThreshold., красная зона: >&redThreshold..";
		%m_population_stability_index(rawDataSet=__WORK_SET, inputVarList=&inputVarList., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
									  factorLabelSet=&factorLabelSet., yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
		Title1;
	%end;
	
	%if "&subModelVar." ^= "0" %then %do;
		Title2 h=12pt justify=left "5.2. Результаты теста PSI для расчетных значений факторов";
		Title3 h=12pt justify=left
		"Желтая зона: &yellowThreshold. - &redThreshold., красная зона: >&redThreshold..";
		%m_population_stability_index(rawDataSet=__WORK_SET, inputVarList=&subModelVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
									  factorLabelSet=&factorLabelSet., yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
		Title1;
	%end;
	
	%if "&inputVarList." ^= "0" %then %do;
		*** Выбор пороговых значений;
		proc sql noprint;
			select yellow_threshold, red_threshold
			into :yellowThreshold, :redThreshold
			from &thresholdSet.
			where macro_name = 'm_mann_whitney'
				and ordinal_number = 2;
		quit;
		
		Title2 h=12pt justify=left "5.3. Результаты U-статистики Манна-Уитни для исходных модельных факторов ";
		Title3 h=12pt justify=left
		"Желтая зона: %sysfunc(putn(&redThreshold., percentn7.2)) - %sysfunc(putn(&yellowThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redThreshold., percentn7.2)).";
		%m_mann_whitney(rawDataSet=__WORK_SET, inputVarList=&inputVarList., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
						factorLabelSet=&factorLabelSet., yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
		Title1;
	%end;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete __DEVELOPMENT_SET __VALIDATION_SET __WORK_SET __PORTFOLIO_SET __REPRESENTATIVENESS __N_VALIDATIONS_SET __ROC_SET;
	run;
	
	ods _all_ close;

%mend m_create_LGD_validation_report;


%macro m_information_table_RR(rawDataSet=, actualVar=, periodVar=, periodLabelVar=);
	/* 
		Назначение: Вывод информации о количестве наблюдений и среднем значении уровня возмещения в разрезе периодов.
	   
		Параметры:  rawDataSet     - Имя входного набора данных.
					actualVar	   - Имя фактической переменной.
					periodVar	   - Имя переменной, определяющей период.
					periodLabelVar - Имя переменной, определяющей текстовую метку периода.
	*/

	proc sql;
		create table REPORT_SET as
		select &periodLabelVar.,
			&periodVar.,
			count(*) as observations_count,
			avg(&actualVar.) as average_RR format 7.2
		from &rawDataSet.
		group by &periodLabelVar., &periodVar.
		order by &periodVar.;
	quit;
		
	proc print data=REPORT_SET noobs label;
		var &periodLabelVar. observations_count average_RR;
		label   &periodLabelVar.="Период"
				observations_count="Число наблюдений"
				average_RR="Среднее значение уровня возмещения"; 
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete REPORT_SET;
	run;

%mend m_information_table_RR;


%macro m_print_modif_gini_rr(rawValDataSet=, rawDevDataSet=, outputVar=, actualVar=, inputVarList=, periodVar=, factorLabelSet=,
							 yellowFactorThreshold=, redFactorThreshold=, yellowModelThreshold=, redModelThreshold=,
							 yellowRelativeThreshold=, redRelativeThreshold=);
	/* 
		Назначение: Расчет модифицированного коэффициента Джини для входных переменных в разрезе периодов,
					расчет модифицированного коэффициента Джини для выходной переменной в разрезе периодов.
	   
		Параметры:  rawValDataSet   - Имя выборки для валидации.
					rawDevDataSet   - Имя выборки для разработки.
					outputVar	    - Имя выходной переменной модели.
					actualVar	    - Имя фактической переменной.
					inputVarList    - Строка, содержащая перечень имен входных переменных, разделитель - '|'.
								      Пример: variable1|variable2|variable3.
					periodVar       - Имя переменной, определяющей период.
							          Выборка для разработки - periodVar = 1,
								      выборка для валидации - periodVar = max(periodVar).
					factorLabelSet	- Набор данных, содержащий лейблы для факторов.
									  Должен содержать следующий набор полей:
											factor character			- название фактора,
											factor_label character		- лейбл фактора.
					yellowFactorThreshold	- Желтое пороговое значение для факторов.
					redFactorThreshold		- Красное пороговое значение для факторов.
					yellowModelThreshold	- Желтое пороговое значение для модели.
					redModelThreshold		- Красное пороговое значение для модели.
					yellowRelativeThreshold - Относительное желтое пороговое значение.
					redRelativeThreshold	- Относительное красное пороговое значение.
								   
		Вызываемые макросы:
					m_get_simple_modif_gini	 - Расчет модифицированного коэффициента Джини для одного периода,
											   выходная таблица - OUTPUT_M_GET_SIMPLE_MODIF_GINI.
					m_get_modif_gini		 - Расчет модифицированного коэффициента Джини,
											   выходная таблица - OUTPUT_M_GET_MODIF_GINI.
	*/
	
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Определение количества входных переменных;
	%let inputVarCnt=%SYSFUNC(countw(&inputVarList.,%STR('|')));
	
	*** Выполнение промежуточных расчетов для входных и для выходной переменной модели;
	%m_get_modif_gini(rawValDataSet=&rawValDataSet., rawDevDataSet=&rawDevDataSet., actualVar=&actualVar.,
					  inputVarList=&inputVarList.|&outputVar.,
					  yellowRelativeThreshold=&yellowRelativeThreshold., redRelativeThreshold=&redRelativeThreshold.);
	
	data GINI_INPUT_VARS;
		set OUTPUT_M_GET_MODIF_GINI;
		where factor ^= "&outputVar.";
		format light_dev light_val $30.;
		
		old_gini_lower_dev = gini_lower_dev;
		old_gini_upper_dev = gini_upper_dev;
		if gini_dev < 0 then do;
			gini_dev = abs(gini_dev);
			gini_lower_dev = -1 * old_gini_upper_dev;
			gini_upper_dev = -1 * old_gini_lower_dev;
		end;
		select;
			when (gini_lower_dev < &redFactorThreshold.)	light_dev = "красный";
			when (gini_lower_dev < &yellowFactorThreshold.) light_dev = "желтый";
			otherwise										light_dev = "зеленый";
		end;
		
		old_gini_lower_val = gini_lower_val;
		old_gini_upper_val = gini_upper_val;
		if gini_val < 0 then do;
			gini_val = abs(gini_val);
			gini_lower_val = -1 * old_gini_upper_val;
			gini_upper_val = -1 * old_gini_lower_val;
		end;
		select;
			when (gini_lower_val < &redFactorThreshold.)	light_val = "красный";
			when (gini_lower_val < &yellowFactorThreshold.) light_val = "желтый";
			otherwise										light_val = "зеленый";
		end;
	run;
	
	*** Выбор лейбла фактора;
	proc sql noprint;
		create table REPORT_SET_GINI_INPUT as
		select a.*,
				trim(a.factor) || ': ' || trim(b.factor_label) as factor_label
		from GINI_INPUT_VARS as a
		left join &factorLabelSet. as b
			on upcase(a.factor) = upcase(b.factor);
	quit;
	
	data GINI_OUTPUT_VAR;
		set OUTPUT_M_GET_MODIF_GINI;
		where factor = "&outputVar";
		format light_dev light_val $30.;
		select;
			when (gini_lower_dev < &redModelThreshold.)	   light_dev = "красный";
			when (gini_lower_dev < &yellowModelThreshold.) light_dev = "желтый";
			otherwise									   light_dev = "зеленый";
		end;
		
		select;
			when (gini_lower_val < &redModelThreshold.)	   light_val = "красный";
			when (gini_lower_val < &yellowModelThreshold.) light_val = "желтый";
			otherwise									   light_val = "зеленый";
		end;
	run;
	
	*** Выбор лейбла фактора;
	proc sql noprint;
		create table REPORT_SET_GINI_OUTPUT as
		select a.*,
				trim(a.factor) || ': ' || trim(b.factor_label) as factor_label
		from GINI_OUTPUT_VAR as a
		left join &factorLabelSet. as b
			on upcase(a.factor) = upcase(b.factor);
	quit;
	
	
	***																										  ;
	*** Расчет модифицированного коэффициента Джини для факторов модели на выборках для разработки и валидации;
	***																										  ;
	
	Title3 h=12pt justify=left "Расчет модифицированного коэффициента Джини для факторов модели на выборках для разработки и валидации";
	Title4 h=12pt justify=left
	"Абсолютное значение. Желтая зона: %sysfunc(putn(&redFactorThreshold., percentn7.2)) - %sysfunc(putn(&yellowFactorThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redFactorThreshold., percentn7.2)).";
	Title5 h=12pt justify=left
	"Относительная разница. Желтая зона: %sysfunc(putn(&yellowRelativeThreshold., percentn7.2)) - %sysfunc(putn(&redRelativeThreshold., percentn7.2)), красная зона: >%sysfunc(putn(&redRelativeThreshold., percentn7.2)).";
	Title6 h=12pt "Выборка для разработки";
	
	proc report data=REPORT_SET_GINI_INPUT SPLIT='';
		column factor_label gini_dev gini_lower_dev gini_upper_dev light_dev;
		define factor_label /	display "Фактор"
								style(column)=[fontsize=1]
								style(header)=[fontsize=1];
		define gini_dev /	display "Джини"
							style(header)=[fontsize=1];
		define gini_lower_dev / display "Нижняя граница"
								style(header)=[fontsize=1];
		define gini_upper_dev / display "Верхняя граница"
								style(header)=[fontsize=1];
		define light_dev /	display "Светофор"
							style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
							style(header)=[fontsize=1];
	run;
	
	Title1;
	
	Title6 h=12pt "Выборка для валидации";
	
	proc report data=REPORT_SET_GINI_INPUT SPLIT='';
		column factor_label gini_val gini_lower_val gini_upper_val light_val diff light_rel;
		define factor_label /	display "Фактор"
								style(column)=[fontsize=1]
								style(header)=[fontsize=1];
		define gini_val /	display "Джини"
							style(header)=[fontsize=1];
		define gini_lower_val / display "Нижняя граница"
								style(header)=[fontsize=1];
		define gini_upper_val / display "Верхняя граница"
								style(header)=[fontsize=1];
		define light_val /	display "Светофор, абсолютное значение"
							style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
							style(header)=[fontsize=1];
		define diff /	display "Относительная разница(%)"
						style(header)=[fontsize=1];
		define light_rel /	display "Светофор, относительная разница"
							style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
							style(header)=[fontsize=1];
	run;
	
	Title1;
	
	
	***																									   ;
	*** Расчет модифицированного коэффициента Джини на уровне модели на выборках для разработки и валидации;
	***																									   ;
	
	Title3 h=12pt justify=left "Расчет модифицированного коэффициента Джини на уровне модели на выборках для разработки и валидации";
	Title4 h=12pt justify=left
	"Абсолютное значение. Желтая зона: %sysfunc(putn(&redModelThreshold., percentn7.2)) - %sysfunc(putn(&yellowModelThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redModelThreshold., percentn7.2)).";
	Title5 h=12pt justify=left
	"Относительная разница. Желтая зона: %sysfunc(putn(&yellowRelativeThreshold., percentn7.2)) - %sysfunc(putn(&redRelativeThreshold., percentn7.2)), красная зона: >%sysfunc(putn(&redRelativeThreshold., percentn7.2)).";
	
	proc print data= REPORT_SET_GINI_OUTPUT noobs label;
		var gini_dev gini_lower_dev gini_upper_dev;
		var light_dev / style(data)=[background=$BACKCOLOR_FMT.];
		var gini_val gini_lower_val gini_upper_val;
		var light_val / style(data)=[background=$BACKCOLOR_FMT.];
		var diff;
		var light_rel / style(data)=[background=$BACKCOLOR_FMT.];
		label   gini_dev="Джини, разработка"
				gini_lower_dev="Нижняя граница, разработка"
				gini_upper_dev="Верхняя граница, разработка"
				light_dev="Светофор, разработка"
				gini_val="Джини, валидация"
				gini_lower_val="Нижняя граница, валидация"
				gini_upper_val="Верхняя граница, валидация"
				light_val="Светофор, валидация"
				diff="Относительная разница(%)"
				light_rel="Светофор, относительная разница";
	run;
	
	Title1;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete GINI_INPUT_VARS GINI_OUTPUT_VAR OUTPUT_M_GET_MODIF_GINI REPORT_SET_GINI_OUTPUT REPORT_SET_GINI_INPUT;
	run;

%mend m_print_modif_gini_rr;


%macro m_create_RR_validation_report(rawDataSet=, modelDesc=, outputVar=, actualVar=, inputVarList=, inputVarList_gr=,
									 periodVar=, periodLabelVar=, factorBinLabelSet=, factorLabelSet=, thresholdSet=);
	/* 
		Назначение: Валидация модели RECOVERY RATE.
	   
		Параметры:  rawDataSet		 - Имя входного набора данных.
					modelDesc		 - Описание модели.
					outputVar		 - Имя выходной переменной модели.
					actualVar		 - Имя фактической переменной.
					inputVarList	 - Строка, содержащая перечень имен переменных, разделитель - '|'.
									   Пример: variable1|variable2|variable3.
					inputVarList_gr  - Строка, содержащая перечень имен групповых переменных, разделитель - '|'.
									   Пример: variable1|variable2|variable3.
					periodVar		 - Имя переменной, определяющей период.
									   Выборка для разработки - periodVar = 1,
									   выборки для валидации - последующие периоды (значения: 2, 3, 4 и т.д.).
					periodLabelVar	 - Имя переменной, определяющей текстовую метку периода.
					factorBinLabelSet- Набор данных, содержащий лейблы для значений бинов.
									   Должен содержать следующий набор полей:
											factor_gr character			- название фактора,
											bin_number integer			- номер бина,
											factor_gr_label character	- лейбл бина.
					factorLabelSet	 - Набор данных, содержащий лейблы для факторов.
									   Должен содержать следующий набор полей:
											factor character			- название фактора,
											factor_label character		- лейбл фактора.
					thresholdSet	 - Набор данных, содержащий пороговые значения.
									   Должен содержать следующий набор полей:
											macro_name character 		- название макроса,
											ordinal_number integer		- порядковый номер пороговых значений,
											yellow_threshold float		- желтое пороговое значение,
											red_threshold float			- красное пороговое значение.
					
		Вызываемые макросы:
					m_information_table_RR
					m_factor_information_table
					m_factor_distribution
					m_group_factor_distribution
					m_print_modif_gini_rr
					m_spearmans_correlation
					m_mann_whitney
					m_population_stability_index
	*/

	*** Определение значения периода валидации;
	proc sql noprint;
		select max(&periodVar.)
		into :valPeriod
		from &rawDataSet.;
	quit;
	
	*** Создание выборки для разработки;
	data __DEVELOPMENT_SET;
		set &rawDataSet.;
		where &periodVar. = 1;
	run;
	
	*** Создание выборки для валидации;
	data __VALIDATION_SET;
		set &rawDataSet.;
		where &periodVar. = &valPeriod.;
	run;
	
	*** Исключение выборки для анализа репрезентативности;
	data __WORK_SET;
		set &rawDataSet.;
		where &periodVar. > 0;
	run;
	
	*** Создание набора для всех периодов валидации;
	data __N_VALIDATIONS_SET;
		set &rawDataSet.;
		where &periodVar. > 1;
	run;
	
	Title1 h=26pt "Сводная информация";
	Title2 "Модель &modelDesc.";
	Title3 "Дата и время создания отчета: &sysdate9., &systime. &sysday.; пользователь: &sysuserid.";
	%m_information_table_RR(rawDataSet=__WORK_SET, actualVar=&actualVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.);
	
	Title1 h=26pt "1. Анализ качества данных";
	Title2 h=12pt justify=left "1.1. Сводная информация по факторам модели";
	%m_factor_information_table(rawDataSet=__WORK_SET, inputVarList=&inputVarList., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
								factorLabelSet=&factorLabelSet.);
	Title1;
	
	Title2 h=12pt justify=left "1.2. Распределение значений факторов";	
	%m_factor_distribution(rawValDataSet=__VALIDATION_SET, rawDevDataSet=__DEVELOPMENT_SET, inputVarList=&inputVarList., factorLabelSet=&factorLabelSet.);
	
	%let y2label = Средний уровень возмещения;

	Title1 h=26pt "2. Предсказательная способность модели";
	Title2 h=12pt justify=left "2.1. Анализ чувствительности риск-факторов";
	%m_group_factor_distribution(rawValDataSet=__VALIDATION_SET, rawDevDataSet=__DEVELOPMENT_SET, actualVar=&actualVar., inputVarList=&inputVarList_gr.,
								 factorBinLabelSet=&factorBinLabelSet., factorLabelSet=&factorLabelSet., y2label=&y2label.);
						   
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowModelThreshold, :redModelThreshold
		from &thresholdSet.
		where macro_name = 'm_print_modif_gini' and ordinal_number = 1;
		
		select yellow_threshold, red_threshold
		into :yellowRelativeThreshold, :redRelativeThreshold
		from &thresholdSet.
		where macro_name = 'm_print_modif_gini' and ordinal_number = 2;
		
		select yellow_threshold, red_threshold
		into :yellowFactorThreshold, :redFactorThreshold
		from &thresholdSet.
		where macro_name = 'm_print_modif_gini' and ordinal_number = 3;
	quit;

	Title2 h=12pt justify=left "2.2. Значение предсказательной способности";
	%m_print_modif_gini(rawValDataSet=__VALIDATION_SET, rawDevDataSet=__DEVELOPMENT_SET, outputVar=&outputVar., actualVar=&actualVar.,
						inputVarList=&inputVarList_gr., factorLabelSet=&factorLabelSet.,
						yellowFactorThreshold=&yellowFactorThreshold., redFactorThreshold=&redFactorThreshold.,
						yellowModelThreshold=&yellowModelThreshold., redModelThreshold=&redModelThreshold.,
						yellowRelativeThreshold=&yellowRelativeThreshold., redRelativeThreshold=&redRelativeThreshold.);
						   
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_spearmans_correlation';
	quit;
						
	Title2 h=12pt justify=left "2.3. Корреляция Спирмена";
	Title3 h=12pt justify=left
	"Желтая зона: %sysfunc(putn(&redThreshold., percentn7.2)) - %sysfunc(putn(&yellowThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redThreshold., percentn7.2)).";
	%m_spearmans_correlation(rawDataSet=__N_VALIDATIONS_SET, outputVar=&outputVar., actualVar=&actualVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
							 yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	Title1;
	
	*** Выбор пороговых значений;	
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_population_stability_index';
	quit;
	
	%let yellowThreshold = %sysfunc(putn(&yellowThreshold.,best18.));
	%let redThreshold = %sysfunc(putn(&redThreshold.,best18.));
	
	Title1 h=26pt "5. Стабильность";
	Title2 h=12pt justify=left "5.1. Результаты Теста PSI для исходных модельных факторов";
	Title3 h=12pt justify=left
	"Желтая зона: &yellowThreshold. - &redThreshold., красная зона: >&redThreshold..";
	%m_population_stability_index(rawDataSet=__WORK_SET, inputVarList=&inputVarList., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
								  factorLabelSet=&factorLabelSet., yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	Title1;
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_mann_whitney'
			and ordinal_number = 2;
	quit;	
	
	Title2 h=12pt justify=left "5.2. Результаты U-статистики Манна-Уитни для исходных модельных факторов ";
	Title3 h=12pt justify=left
	"Желтая зона: %sysfunc(putn(&redThreshold., percentn7.2)) - %sysfunc(putn(&yellowThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redThreshold., percentn7.2)).";
	%m_mann_whitney(rawDataSet=__WORK_SET, inputVarList=&inputVarList., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
					factorLabelSet=&factorLabelSet., yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	Title1;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete __DEVELOPMENT_SET __VALIDATION_SET __WORK_SET __N_VALIDATIONS_SET;
	run;
	
	ods _all_ close;
%mend m_create_RR_validation_report;


%macro m_information_table_PCURE(rawDataSet=, actualVar=, periodVar=, periodLabelVar=);
	/* 
		Назначение: Вывод информации о количестве наблюдений и вероятности восстановления в разрезе периодов.
	   
		Параметры:  rawDataSet     - Имя входного набора данных.
					actualVar	   - Имя фактической переменной.
					periodVar	   - Имя переменной, определяющей период.
					periodLabelVar - Имя переменной, определяющей текстовую метку периода.
	*/

	proc sql;
		create table REPORT_SET as
		select &periodLabelVar.,
			&periodVar.,
			count(*) as observations_count,
			sum(&actualVar.) as pcure_count,
			(calculated pcure_count / calculated observations_count) as pcure_rate format percentn7.2
		from &rawDataSet.
		group by &periodLabelVar., &periodVar.
		order by &periodVar.;
	quit;
		
	proc print data=REPORT_SET noobs label;
		var &periodLabelVar. observations_count pcure_count pcure_rate;
		label   &periodLabelVar.="Период"
				observations_count="Число наблюдений"
				pcure_count="Количество выздоровлений"
				pcure_rate="Процент выздоровлений"; 
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete REPORT_SET;
	run;

%mend m_information_table_PCURE;


%macro m_create_PCURE_validation_report(rawDataSet=, modelDesc=, outputVar=, actualVar=, inputVarList=, inputVarList_gr=,
										periodVar=, periodLabelVar=, factorBinLabelSet=, factorLabelSet=, thresholdSet=);
	/* 
		Назначение: Валидация модели PROBABILITY OF CURE.
	   
		Параметры:  rawDataSet		 - Имя входного набора данных.
					modelDesc		 - Описание модели.
					outputVar		 - Имя выходной переменной модели.
					actualVar		 - Имя фактической переменной.
					inputVarList	 - Строка, содержащая перечень имен переменных, разделитель - '|'.
									   Пример: variable1|variable2|variable3.
					inputVarList_gr  - Строка, содержащая перечень имен групповых переменных, разделитель - '|'.
									   Пример: variable1|variable2|variable3.
					periodVar		 - Имя переменной, определяющей период.
									   Выборка для разработки - periodVar = 1,
									   выборки для валидации - последующие периоды (значения: 2, 3, 4 и т.д.).
					periodLabelVar	 - Имя переменной, определяющей текстовую метку периода.
					factorBinLabelSet- Набор данных, содержащий лейблы для значений бинов.
									   Должен содержать следующий набор полей:
											factor_gr character			- название фактора,
											bin_number integer			- номер бина,
											factor_gr_label character	- лейбл бина.
					factorLabelSet	 - Набор данных, содержащий лейблы для факторов.
									   Должен содержать следующий набор полей:
											factor character			- название фактора,
											factor_label character		- лейбл фактора.
					thresholdSet	 - Набор данных, содержащий пороговые значения.
									   Должен содержать следующий набор полей:
											macro_name character 		- название макроса,
											ordinal_number integer		- порядковый номер пороговых значений,
											yellow_threshold float		- желтое пороговое значение,
											red_threshold float			- красное пороговое значение.
					
		Вызываемые макросы:
					m_factor_distribution
					m_pcure_level
					m_print_gini
					m_mann_whitney
					m_population_stability_index
	*/

	*** Определение значения периода валидации;
	proc sql noprint;
		select max(&periodVar.)
		into :valPeriod
		from &rawDataSet.;
	quit;
	
	*** Создание выборки для разработки;
	data __DEVELOPMENT_SET;
		set &rawDataSet.;
		where &periodVar. = 1;
	run;
	
	*** Создание выборки для валидации;
	data __VALIDATION_SET;
		set &rawDataSet.;
		where &periodVar. = &valPeriod.;
	run;
	
	*** Исключение выборки для анализа репрезентативности;
	data __WORK_SET;
		set &rawDataSet.;
		where &periodVar. > 0;
	run;

	Title1 h=26pt "Сводная информация";
	Title2 "Модель &modelDesc.";
	Title3 "Дата и время создания отчета: &sysdate9., &systime. &sysday.; пользователь: &sysuserid.";
	%m_information_table_PCURE(rawDataSet=__WORK_SET, actualVar=&actualVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.);
	
	Title1 h=26pt "1. Анализ качества данных";
	%m_factor_information_table(rawDataSet=__WORK_SET, inputVarList=&inputVarList., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
								factorLabelSet=&factorLabelSet.);
	
	Title1 h=26pt "2. Предсказательная способность модели";
	Title2 h=12pt justify=left "2.1. Распределение исходных факторов модели";
	%m_factor_distribution(rawValDataSet=__VALIDATION_SET, rawDevDataSet=__DEVELOPMENT_SET, inputVarList=&inputVarList., factorLabelSet=&factorLabelSet.);
	
	%let y2label = Процент выздоровления;
	
	Title2 h=16pt justify=left "2.2. Уровень дефолта и концентрация наблюдений по категориям факторов";
	%m_group_factor_distribution(rawValDataSet=__VALIDATION_SET, rawDevDataSet=__DEVELOPMENT_SET, actualVar=&actualVar., inputVarList=&inputVarList_gr.,
								 factorBinLabelSet=&factorBinLabelSet., factorLabelSet=&factorLabelSet., y2label=&y2label.);
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowModelThreshold, :redModelThreshold
		from &thresholdSet.
		where macro_name = 'm_print_gini' and ordinal_number = 1;
		
		select yellow_threshold, red_threshold
		into :yellowRelativeThreshold, :redRelativeThreshold
		from &thresholdSet.
		where macro_name = 'm_print_gini' and ordinal_number = 2;
		
		select yellow_threshold, red_threshold
		into :yellowFactorThreshold, :redFactorThreshold
		from &thresholdSet.
		where macro_name = 'm_print_gini' and ordinal_number = 3;
	quit;

	Title2 h=12pt justify=left "2.3. Значение предсказательной способности";
	Title3 h=12pt justify=left "Расчет коэффициента Джини для факторов модели на выборках для разработки и валидации";
	Title4 h=12pt justify=left
	"Абсолютное значение. Желтая зона: %sysfunc(putn(&redFactorThreshold., percentn7.2)) - %sysfunc(putn(&yellowFactorThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redFactorThreshold., percentn7.2)).";
	Title5 h=12pt justify=left
	"Относительная разница. Желтая зона: %sysfunc(putn(&yellowRelativeThreshold., percentn7.2)) - %sysfunc(putn(&redRelativeThreshold., percentn7.2)), красная зона: >%sysfunc(putn(&redRelativeThreshold., percentn7.2)).";
	%m_print_gini(rawDataSet=__WORK_SET, actualVar=&actualVar., inputVarList=&inputVarList_gr.,
				  periodVar=&periodVar., periodLabelVar=&periodLabelVar., factorLabelSet=&factorLabelSet.,
				  yellowThreshold=&yellowFactorThreshold., redThreshold=&redFactorThreshold.,
				  yellowRelativeThreshold=&yellowRelativeThreshold., redRelativeThreshold=&redRelativeThreshold.,
				  titleNum=6);
				  
	Title3 h=12pt justify=left "Расчет коэффициента Джини на уровне модели на выборках для разработки и валидации";
	Title4 h=12pt justify=left
	"Абсолютное значение. Желтая зона: %sysfunc(putn(&redModelThreshold., percentn7.2)) - %sysfunc(putn(&yellowModelThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redModelThreshold., percentn7.2)).";
	Title5 h=12pt justify=left
	"Относительная разница. Желтая зона: %sysfunc(putn(&yellowRelativeThreshold., percentn7.2)) - %sysfunc(putn(&redRelativeThreshold., percentn7.2)), красная зона: >%sysfunc(putn(&redRelativeThreshold., percentn7.2)).";
	%m_print_gini(rawDataSet=__WORK_SET, actualVar=&actualVar., inputVarList=&outputVar.,
				  periodVar=&periodVar., periodLabelVar=&periodLabelVar., factorLabelSet=&factorLabelSet.,
				  yellowThreshold=&yellowModelThreshold., redThreshold=&redModelThreshold.,
				  yellowRelativeThreshold=&yellowRelativeThreshold., redRelativeThreshold=&redRelativeThreshold.);

	*** Выбор пороговых значений;	
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_population_stability_index';
	quit;
	
	%let yellowThreshold = %sysfunc(putn(&yellowThreshold.,best18.));
	%let redThreshold = %sysfunc(putn(&redThreshold.,best18.));					
						
	Title1 h=26pt "5. Стабильность модели на уровне факторов";
	Title2 h=12pt justify=left "5.1. Результаты Теста PSI для исходных модельных факторов";
	Title3 h=12pt justify=left
	"Желтая зона: &yellowThreshold. - &redThreshold., красная зона: >&redThreshold..";
	%m_population_stability_index(rawDataSet=__WORK_SET, inputVarList=&inputVarList., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
								  factorLabelSet=&factorLabelSet., yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	Title1;
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_mann_whitney'
			and ordinal_number = 2;
	quit;
	
	Title2 h=12pt justify=left "5.2. Результаты U-статистики Манна-Уитни для исходных модельных факторов";
	Title3 h=12pt justify=left
	"Желтая зона: %sysfunc(putn(&redThreshold., percentn7.2)) - %sysfunc(putn(&yellowThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redThreshold., percentn7.2)).";
	%m_mann_whitney(rawDataSet=__WORK_SET, inputVarList=&inputVarList., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
					factorLabelSet=&factorLabelSet., yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	Title1;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete __DEVELOPMENT_SET __VALIDATION_SET __WORK_SET;
	run;
	
	ods _all_ close;
	
%mend m_create_PCURE_validation_report;


%macro m_information_table_EAD(rawDataSet=, actualVar=, periodVar=, periodLabelVar=);
	/* 
		Назначение: Вывод информации о количестве наблюдений и среднем значении EAD в разрезе периодов.
	   
		Параметры:  rawDataSet     - Имя входного набора данных.
					actualVar	   - Имя фактической переменной.
					periodVar	   - Имя переменной, определяющей период.
									 Выборка для разработки - periodVar = 1,
									 выборки для валидации - последующие периоды (значения: 2, 3, 4 и т.д.).
					periodLabelVar - Имя переменной, определяющей текстовую метку периода.
	*/

	proc sql;
		create table REPORT_SET as
		select &periodLabelVar.,
			&periodVar.,
			count(*) as observations_count,
			avg(&actualVar.) as average_EAD format 7.2
		from &rawDataSet.
		group by &periodLabelVar., &periodVar.
		order by &periodVar.;
	quit;
		
	proc print data=REPORT_SET noobs label;
		var &periodLabelVar. observations_count average_EAD;
		label   &periodLabelVar.="Период"
				observations_count="Число наблюдений"
				average_LGD="Среднее значение EAD";
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete REPORT_SET;
	run;

%mend m_information_table_EAD;


%macro m_create_EAD_validation_report(rawDataSet=, modelDesc=, outputVar=, actualVar=, outputVarPD=, actualsubModelVar=,
									  outputsubModelVar=, inputVarList=, inputVarList_gr=,
									  periodVar=, periodLabelVar=, factorBinLabelSet=, factorLabelSet=, thresholdSet=);
	/* 
		Назначение: Валидация модели EAD.
	   
		Параметры:  rawDataSet		  - Имя входного набора данных.
					modelDesc		  - Описание модели.
					outputVar		  - Имя выходной переменной модели.
					actualVar		  - Имя фактической переменной.
					outputVarPD		  - Имя выходной переменной PD.
					actualsubModelVar - Имя фактической переменной подмодели CCF.
					outputsubModelVar - Имя выходной переменной подмодели CCF.
					inputVarList	  - Строка, содержащая перечень имен переменных, разделитель - '|'.
									    Пример: variable1|variable2|variable3.
					inputVarList_gr   - Строка, содержащая перечень имен групповых переменных, разделитель - '|'.
									    Пример: variable1|variable2|variable3.
					periodVar		  - Имя переменной, определяющей период.
									    Выборка для разработки - periodVar = 1,
									    выборки для валидации - последующие периоды (значения: 2, 3, 4 и т.д.).
					periodLabelVar	  - Имя переменной, определяющей текстовую метку периода.
					factorBinLabelSet - Набор данных, содержащий лейблы для значений бинов.
									    Должен содержать следующий набор полей:
											factor_gr character			- название фактора,
											bin_number integer			- номер бина,
											factor_gr_label character	- лейбл бина.
					factorLabelSet	  - Набор данных, содержащий лейблы для факторов.
									    Должен содержать следующий набор полей:
											factor character			- название фактора,
											factor_label character		- лейбл фактора.
					thresholdSet	  - Набор данных, содержащий пороговые значения.
									    Должен содержать следующий набор полей:
											macro_name character 		- название макроса,
											ordinal_number integer		- порядковый номер пороговых значений,
											yellow_threshold float		- желтое пороговое значение,
											red_threshold float			- красное пороговое значение.
					
		Вызываемые макросы:
					m_information_table_EAD
					m_factor_information_table
					m_factor_distribution
					m_group_factor_distribution
					m_print_modif_gini
					m_roc_curve
					m_spearmans_correlation
					m_r_squared
					m_root_mean_square_err
					m_t_test
					m_mann_whitney
					m_population_stability_index
	*/
	
	*** Определение значения периода валидации;
	proc sql noprint;
		select max(&periodVar.)
		into :valPeriod
		from &rawDataSet.;
	quit;
	
	*** Создание выборки для разработки;
	data __DEVELOPMENT_SET;
		set &rawDataSet.;
		where &periodVar. = 1;
	run;
	
	*** Создание выборки для валидации;
	data __VALIDATION_SET;
		set &rawDataSet.;
		where &periodVar. = &valPeriod.;
	run;
	
	*** Создание набора для всех периодов валидации;
	data __N_VALIDATIONS_SET;
		set &rawDataSet.;
		where &periodVar. > 1;
	run;
	
	*** Исключение выборки для анализа репрезентативности;
	data __WORK_SET;
		set &rawDataSet.;
		where &periodVar. > 0;
	run;
	
	Title1 h=26pt "Сводная информация";
	Title2 "Модель &modelDesc.";
	Title3 "Дата и время создания отчета: &sysdate9., &systime. &sysday.; пользователь: &sysuserid.";
	%m_information_table_EAD(rawDataSet=__WORK_SET, actualVar=&actualVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.);
	
	Title1 h=26pt "1. Анализ качества данных";
	Title2 h=12pt justify=left "1.1. Сводная информация по факторам модели";
	%m_factor_information_table(rawDataSet=__WORK_SET, inputVarList=&inputVarList., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
								factorLabelSet=&factorLabelSet.);
	
	Title2 h=12pt justify=left "1.2. Распределение значений факторов";	
	%m_factor_distribution(rawValDataSet=__VALIDATION_SET, rawDevDataSet=__DEVELOPMENT_SET, inputVarList=&inputVarList., factorLabelSet=&factorLabelSet.);
	
	%let y2label = Среднее значение CCF;
	
	Title1 h=26pt "2. Предсказательная способность модели";
	Title2 h=12pt justify=left "2.1. Анализ чувствительности риск-факторов";
	%m_group_factor_distribution(rawValDataSet=__VALIDATION_SET, rawDevDataSet=__DEVELOPMENT_SET, actualVar=&actualsubModelVar., inputVarList=&inputVarList_gr.,
								 factorBinLabelSet=&factorBinLabelSet., factorLabelSet=&factorLabelSet., y2label=&y2label.);
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowModelThreshold, :redModelThreshold
		from &thresholdSet.
		where macro_name = 'm_print_modif_gini' and ordinal_number = 1;
		
		select yellow_threshold, red_threshold
		into :yellowRelativeThreshold, :redRelativeThreshold
		from &thresholdSet.
		where macro_name = 'm_print_modif_gini' and ordinal_number = 2;
		
		select yellow_threshold, red_threshold
		into :yellowFactorThreshold, :redFactorThreshold
		from &thresholdSet.
		where macro_name = 'm_print_modif_gini' and ordinal_number = 3;
	quit;
	
	Title2 h=12pt justify=left "2.2. Значение предсказательной способности на уровне CCF";
	%m_print_modif_gini(rawValDataSet=__VALIDATION_SET, rawDevDataSet=__DEVELOPMENT_SET, outputVar=&outputsubModelVar., actualVar=&actualsubModelVar.,
						actualVarEAD=&actualVar., inputVarList=&inputVarList_gr.,
						factorLabelSet=&factorLabelSet., yellowFactorThreshold=&yellowFactorThreshold., redFactorThreshold=&redFactorThreshold.,
						yellowModelThreshold=&yellowModelThreshold., redModelThreshold=&redModelThreshold.,
						yellowRelativeThreshold=&yellowRelativeThreshold., redRelativeThreshold=&redRelativeThreshold.);
	
	*** Объединение набора для разработки и набора для валидации;
	data __ROC_SET;
		set __DEVELOPMENT_SET __VALIDATION_SET;
	run;
	
	Title1 "ROC-кривая &outputsubModelVar. на выборках для разработки и валидации";
	%m_roc_curve(rawDataSet=__ROC_SET, inputVar=&outputsubModelVar., actualVar=&actualsubModelVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.);
	Title1;
	
	Title2 h=12pt justify=left "2.3. Значение предсказательной способности на уровне EAD";
	%m_print_modif_gini(rawValDataSet=__VALIDATION_SET, rawDevDataSet=__DEVELOPMENT_SET,  actualVar=&actualVar.,outputVar=&outputVar., 
						factorLabelSet=&factorLabelSet.,
						yellowModelThreshold=&yellowModelThreshold., redModelThreshold=&redModelThreshold.,
						yellowRelativeThreshold=&yellowRelativeThreshold., redRelativeThreshold=&redRelativeThreshold.);
						
	Title1 "ROC-кривая &outputVar. на выборках для разработки и валидации";
	%m_roc_curve(rawDataSet=__ROC_SET, inputVar=&outputVar., actualVar=&actualVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.);
	Title1;
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_spearmans_correlation';
	quit;
	
	Title2 h=12pt justify=left "2.3. Корреляция Спирмена";
	Title3 h=12pt justify=left
	"Желтая зона: %sysfunc(putn(&redThreshold., percentn7.2)) - %sysfunc(putn(&yellowThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redThreshold., percentn7.2)).";
	%m_spearmans_correlation(rawDataSet=__N_VALIDATIONS_SET, outputVar=&outputVar., actualVar=&actualVar.,
							 periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
							 yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	Title1;
							 
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_r_squared';
	quit;
	
	Title2 h=12pt justify=left "2.5. Коэффициент детерминации";
	Title3 h=12pt justify=left
	"Желтая зона: %sysfunc(putn(&redThreshold., percentn7.2)) - %sysfunc(putn(&yellowThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redThreshold., percentn7.2)).";
	%m_r_squared(rawDataSet=__N_VALIDATIONS_SET, actualVar=&actualVar., outputVar=&outputVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
				 yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	Title1;
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_root_mean_square_err';
	quit;
	
	Title2 h=12pt justify=left "2.6. Среднеквадратичная ошибка";
	Title3 h=12pt justify=left
	"Желтая зона: %sysfunc(putn(&yellowThreshold., percentn7.2)) - %sysfunc(putn(&redThreshold., percentn7.2)), красная зона: >%sysfunc(putn(&redThreshold., percentn7.2)).";
	%m_root_mean_square_err(rawDataSet=__N_VALIDATIONS_SET, outputVar=&outputVar., actualVar=&actualVar.,
							periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
							yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	
	*** Выбор пороговых значений;
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_loss_shortfall';
	quit;
	
	%let yellowThreshold = %sysfunc(putn(&yellowThreshold.,best18.));
	%let redThreshold = %sysfunc(putn(&redThreshold.,best18.));
	
	
	Title2 h=12pt justify=left "2.7. T-тест / U-статистика Манна-Уитни";
	%m_t_test(rawDataSet=__N_VALIDATIONS_SET, outputVar=&outputVar., actualVar=&actualVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.);
	
	Title3 "Результаты U-статистики Манна-Уитни";
	Title4 h=12pt justify=left "&outputVar.";
	%m_mann_whitney(rawDataSet=__WORK_SET, inputVarList=&outputVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
					factorLabelSet=&factorLabelSet.);
	
	*** Выбор пороговых значений;	
	proc sql noprint;
		select yellow_threshold, red_threshold
		into :yellowThreshold, :redThreshold
		from &thresholdSet.
		where macro_name = 'm_population_stability_index';
	quit;
	
	%let yellowThreshold = %sysfunc(putn(&yellowThreshold.,best18.));
	%let redThreshold = %sysfunc(putn(&redThreshold.,best18.));
	
	Title1 h=26pt "3. Стабильность";
	Title2 h=12pt justify=left "3.1. Результаты Теста PSI для исходных модельных факторов";
	Title3 h=12pt justify=left
	"Желтая зона: &yellowThreshold. - &redThreshold., красная зона: >&redThreshold..";
	%m_population_stability_index(rawDataSet=__WORK_SET, inputVarList=&inputVarList., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
								  factorLabelSet=&factorLabelSet., yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);
	Title1;
	
	Title2 h=12pt justify=left "3.2. Результаты теста PSI для расчетных значений факторов";
	Title3 h=12pt justify=left
	"Желтая зона: &yellowThreshold. - &redThreshold., красная зона: >&redThreshold..";
	%m_population_stability_index(rawDataSet=__WORK_SET, inputVarList=&outputsubModelVar., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
								  factorLabelSet=&factorLabelSet., yellowThreshold=&yellowThreshold., redThreshold=&redThreshold.);

	Title2 h=12pt justify=left "3.3. Результаты U-статистики Манна-Уитни для исходных модельных факторов ";
	%m_mann_whitney(rawDataSet=__WORK_SET, inputVarList=&inputVarList., periodVar=&periodVar., periodLabelVar=&periodLabelVar.,
					factorLabelSet=&factorLabelSet.);
	Title1;
	
	Title1 h=26pt "4. Анализ зависимости PD и EAD";
	Title2 h=12pt justify=left
	"Корреляция Спирмана.";
	%m_spearmans_correlation(rawDataSet=__N_VALIDATIONS_SET, outputVar=&outputVar., actualVar=&outputVarPD., periodVar=&periodVar., periodLabelVar=&periodLabelVar.);
	Title1;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete __DEVELOPMENT_SET __VALIDATION_SET __WORK_SET __N_VALIDATIONS_SET __ROC_SET;
	run;
	
	ods _all_ close;

%mend m_create_EAD_validation_report;

%macro m_relative_PD_IFRS9 (rawDataSet=, actualVar=, outputVar=, yearCnt=, yellowThreshold=0.2, redThreshold=0.3, product_name= , scaleVar=);

data INPUT_SET;
		set &rawDataSet.;
run;

data INPUT_SET;
	set INPUT_SET;
	%do yearIdx = 1 %to &yearCnt;
		YEAR_&yearIdx. = ABS((&actualVar._&yearIdx. - &outputVar._&yearIdx.) / &actualVar._&yearIdx.);
	%end;
KEEP &scaleVar. 	%do yearIdx = 1 %to &yearCnt; 
									YEAR_&yearIdx. 
								%end;
	;
format 
	%do yearIdx = 1 %to &yearCnt;
		YEAR_&yearIdx. percent10.2
		
	%end;
	;
run;


Title h=12pt justify=left "Оценка относительного значения отклонения смоделированных кумулятивных уровней дефолта от эмпирических, макропродукт «"&product_name"» ";
proc report  data=INPUT_SET ;
		%do yearIdx = 1 %to &yearCnt; 
              define YEAR_&yearIdx /display;
              compute YEAR_&yearIdx;
              if (YEAR_&yearIdx > &redThreshold) then
                            call define(_col_,'style','style={background=salmon}');
				if (YEAR_&yearIdx > &yellowThreshold AND YEAR_&yearIdx < &redThreshold) then
                            call define(_col_,'style','style={background=yellow}');
				if  (YEAR_&yearIdx < &yellowThreshold) then
					call define(_col_,'style','style={background=vlig}');
				endcomp;
		%end;
	label &scaleVar. = Рейтинговая категория
		%do yearIdx = 1 %to &yearCnt; 
			YEAR_&yearIdx = Год &yearIdx
		%end;;

run;

%mend m_relative_PD_IFRS9;



%macro m_r_squared_PD_IFRS9 (rawDataSet=, actualVar=, outputVar=, yearCnt=, yellowThreshold=0.9, redThreshold=0.8, product_name= , scaleVar=);

data INPUT_SET;
		set &rawDataSet.;
run; 

%put aaaaaa  &yearCnt;

data INPUT_SET;
	set INPUT_SET;
		RSS = SUM( 
					%do yearIdx = 1 %to &yearCnt; 
						%if "&yearIdx" = "&yearCnt" %then (&actualVar._&yearIdx. - &outputVar._&yearIdx.)**2;
						%else (&actualVar._&yearIdx. - &outputVar._&yearIdx.)**2,; 
					%end;);
		AVG = SUM( 
					%do yearIdx = 1 %to &yearCnt; 
						%if "&yearIdx" = "&yearCnt" %then &actualVar._&yearIdx.;
						%else &actualVar._&yearIdx.,; 
					%end;) / &yearCnt ;
run;

data INPUT_SET;
	set INPUT_SET;
		TSS = SUM( 
					%do yearIdx = 1 %to &yearCnt; 
						%if "&yearIdx" = "&yearCnt" %then (&actualVar._&yearIdx. - AVG)**2;
						%else (&actualVar._&yearIdx. - AVG)**2,; 
					%end;);
run;

data INPUT_SET;
	set INPUT_SET;
		R_SQUARED = 1 - RSS/TSS;
run;

data INPUT_SET;
		set INPUT_SET;
		select;
			when (R_SQUARED < &redThreshold.)	   	light = "красный";
			when (R_SQUARED < &yellowThreshold.) 	light = "желтый";
			otherwise 					   			light = "зеленый";
		end;
		
	format
		R_SQUARED BESTD6.5
		;
	run;

proc format;
	value $BACKCOLOR_FMT 	"зеленый"="vlig"
			  				"желтый"="yellow"
							"красный"="salmon";
run;

Title h=12pt justify=left "Значения коэффициента детерминации, макропродукт «"&product_name"» ";

	proc print data=INPUT_SET noobs label;
		var &scaleVar. R_SQUARED ;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label	&scaleVar. = "Рейтинговая категория"
				R_SQUARED = "R^2"
				light = "Светофор";
	run;

%mend m_r_squared_PD_IFRS9;   



%macro m_RMSE_PD_IFRS9 (rawDataSet=, actualVar=, outputVar=, yearCnt=, yellowThreshold=0.1, redThreshold=0.2, product_name=, scaleVar=);

data INPUT_SET;
		set &rawDataSet.;
run;

data INPUT_SET;
	set INPUT_SET;
		RSS = SUM( 
					%do yearIdx = 1 %to &yearCnt; 
						%if "&yearIdx" = "&yearCnt" %then (&actualVar._&yearIdx. - &outputVar._&yearIdx.)**2;
						%else (&actualVar._&yearIdx. - &outputVar._&yearIdx.)**2,; 
					%end;);

		AVG = SUM( 
					%do yearIdx = 1 %to &yearCnt; 
						%if "&yearIdx" = "&yearCnt" %then &actualVar._&yearIdx.; 
						%else &actualVar._&yearIdx.,; 
					%end;) / &yearCnt ;
run;

data INPUT_SET;
	set INPUT_SET;
		RMSE = sqrt(RSS / (&yearCnt - 1)) / AVG;
run;

data INPUT_SET;
		set INPUT_SET;
		select;
			when (RMSE > &redThreshold.)	   	light = "красный";
			when (RMSE > &yellowThreshold.) 	light = "желтый";
			otherwise 					   		light = "зеленый";
		end;
		format
			RMSE BESTD5.4
		;
	run;

proc format;
	value $BACKCOLOR_FMT 	"зеленый"="vlig"
			  				"желтый"="yellow"
							"красный"="salmon";
run;

Title h=12pt justify=left "Значения показателя RMSE, макропродукт «"&product_name"» ";

	proc print data=INPUT_SET noobs label;
		var &scaleVar. RMSE ;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label	&scaleVar. = "Рейтинговая категория"
				RMSE = "RMSE"
				light = "Светофор";
	run;

%mend m_RMSE_PD_IFRS9;



%macro m_RMSD_PD_IFRS9 (rawDataSet=, actualVar=, outputVar=, yearCnt=, yellowThreshold=0.4, redThreshold=0.3, product_name=, scaleVar = );

data INPUT_SET;
		set &rawDataSet.;
run;

data INPUT_SET;
	set INPUT_SET;
		RSS = SUM( 
					%do yearIdx = 1 %to &yearCnt; 
						%if "&yearIdx" = "&yearCnt" %then (&actualVar._&yearIdx. - &outputVar._&yearIdx.)**2; 
						%else (&actualVar._&yearIdx. - &outputVar._&yearIdx.)**2,; 
					%end;);
run;



data INPUT_SET;
	set INPUT_SET;
		RMSD = sqrt(RSS / &yearCnt);
run;

data INPUT_SET;
		set INPUT_SET;
		select;
			when (RMSD > &redThreshold.)	   	light = "красный";
			when (RMSD > &yellowThreshold.) 	light = "желтый";
			otherwise 					   		light = "зеленый";
		end;
		format
			RMSD BESTD5.4
		;
	run;

proc format;
	value $BACKCOLOR_FMT 	"зеленый"="vlig"
			  				"желтый"="yellow"
							"красный"="salmon";
run;

Title h=12pt justify=left "Значения показателя RMSD, макропродукт «"&product_name"» ";

	proc print data=INPUT_SET noobs label;
		var &scaleVar. RMSD ;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label	&scaleVar. = "Рейтинговая категория"
				RMSD = "RMSD"
				light = "Светофор";
	run;

%mend m_RMSD_PD_IFRS9;



%macro m_graph_cDR (rawDataSet=, actualVar=, outputVar=, yearCnt=, product_name=, scaleVar=);

proc sql noprint;

create table rc_count_table as 
select 
	&scaleVar.
from 
	&rawDataSet;

select 
	count(*)
	into: rc_count
from 
	rc_count_table;

quit;

%let rc_count = &rc_count.;

proc sql noprint;
	select &scaleVar.
	into :var1-:var&rc_count.
	from rc_count_table;
quit;

%put &var1 &var2 &var3 &var4 &var5 &var6;

proc sql;

create table cumDR_graph_1 as 
select 
		&scaleVar.,
		%do yearIdx = 1 %to &yearCnt; 
						%if "&yearIdx" = "&yearCnt" %then &actualVar._&yearIdx.;
						%else &actualVar._&yearIdx.,; 
					%end;
from 
	&rawDataSet;
quit;

Title h=12pt justify=left "Scoring cDR, макропродукт «"&product_name"» ";

proc report  data=cumDR_graph_1 ;

	label &scaleVar. = Рейтинговая категория;
	format
	%do yearIdx = 1 %to &yearCnt; 
						cumDR_&yearIdx. bestd8.7
					%end;
	;

run;

data rc_count_table;
set rc_count_table;
new_rc = 'RC_' || put(_n_,best8. -L);
run;

proc sql;
insert into cumDR_graph_1
	values ( "YEAR", %do yearIdx = 1 %to &yearCnt; 
					%if "&yearIdx" =  "&yearCnt" %then %sysevalf(&yearIdx. - 0.0);
					%else %sysevalf(&yearIdx. - 0.0),;
					%end;);
quit;

proc sql;
create table table_new_rc as 
select 
	*
from 
	rc_count_table as a
	left join cumDR_graph_1 as b
		on a.&scaleVar. = b.&scaleVar.;
quit;

proc sql;
insert into table_new_rc
	values ( "YEAR", "YEAR", %do yearIdx = 1 %to &yearCnt; 
					%if "&yearIdx" =  "&yearCnt" %then %sysevalf(&yearIdx. - 0.0);
					%else %sysevalf(&yearIdx. - 0.0),;
					%end;);
quit;

proc transpose data = table_new_rc out = table_new_rc_2;
id  new_rc;
run;


%let color_1 =BLUE;
%let color_2 =RED;
%let color_3 =GREEN;
%let color_4 =BROWN;
%let color_5 =YELLOW;
%let color_6 =PURPLE;
%let color_7 =GRAY;
%let color_8 =ORANGE;
%let color_9 =turquoise;
%let color_10 =pink;

proc sgplot data=table_new_rc_2;
Title h=12pt justify=left "Scoring cDR, макропродукт «"&product_name"» ";
		%do yearIdx = 1 %to &rc_count; 
					series x=YEAR y=RC_&yearIdx. 	/markers
													LINEATTRS=(color=&&color_&yearIdx.)
													CURVELABEL= "&&var&yearIdx."
													CURVELABELLOC=OUTSIDE;
					yaxis label= "&actualVar" max= 1;
					%end;

run;

%mend m_graph_cDR;


%macro m_graph_cPD (rawDataSet=, actualVar=, outputVar=, yearCnt=, product_name=, scaleVar = );

proc sql noprint;

create table rc_count_table as 
select 
	&scaleVar.
from 
	&rawDataSet;

quit;

proc sql noprint;

select 
	count(*)
	into: rc_count
from 
	rc_count_table;

quit;

%let rc_count = &rc_count.;

proc sql noprint;
	select &scaleVar.
	into :var1-:var&rc_count.
	from rc_count_table;
quit;

%put bbbb &var1 &var2 &var3 &var4 &var5 &var6;

proc sql;

create table cumDR_graph_1 as 
select 
		&scaleVar.,
		%do yearIdx = 1 %to &yearCnt; 
						%if "&yearIdx" = "&yearCnt" %then &actualVar._&yearIdx.;
						%else &actualVar._&yearIdx.,; 
					%end;
from 
	&rawDataSet;
quit;

Title h=12pt justify=left "Scoring cPD, макропродукт «"&product_name"» ";

proc report  data=cumDR_graph_1 ;

	label &scaleVar. = Рейтинговая категория;
	format
	%do yearIdx = 1 %to &yearCnt; 
						cumPD_&yearIdx. bestd8.7
					%end;
	;
run;

data rc_count_table;
set rc_count_table;
new_rc = 'RC_' || put(_n_,best8. -L);
run;

proc sql;
insert into cumDR_graph_1
	values ( "YEAR", %do yearIdx = 1 %to &yearCnt; 
					%if "&yearIdx" =  "&yearCnt" %then %sysevalf(&yearIdx. - 0.0);
					%else %sysevalf(&yearIdx. - 0.0),;
					%end;);
quit;

proc sql;
create table table_new_rc as 
select 
	*
from 
	rc_count_table as a
	left join cumDR_graph_1 as b
		on a.&scaleVar. = b.&scaleVar.;
quit;

proc sql;
insert into table_new_rc
	values ( "YEAR", "YEAR", %do yearIdx = 1 %to &yearCnt; 
					%if "&yearIdx" =  "&yearCnt" %then %sysevalf(&yearIdx. - 0.0);
					%else %sysevalf(&yearIdx. - 0.0),;
					%end;);
quit;

proc transpose data = table_new_rc out = table_new_rc_2;
id  new_rc;
run;

%let color_1 =BLUE;
%let color_2 =RED;
%let color_3 =GREEN;
%let color_4 =BROWN;
%let color_5 =YELLOW;
%let color_6 =PURPLE;
%let color_7 =GRAY;
%let color_8 =ORANGE;
%let color_9 =turquoise;
%let color_10 =pink;

proc sgplot data=table_new_rc_2;
Title h=12pt justify=left "Scoring cPD, макропродукт «"&product_name"» ";
		%do yearIdx = 1 %to &rc_count; 
					series x=YEAR y=RC_&yearIdx. / 	MARKERS
													LINEATTRS=(color=&&color_&yearIdx.)
													CURVELABEL= "&&var&yearIdx."
													CURVELABELLOC=OUTSIDE;
					yaxis label= "&actualVar" max= 1;
					%end;

run;


%mend m_graph_cPD;



%macro m_graph_relative (rawDataSet=, actualVar=, outputVar=, yearCnt=, product_name=, scaleVar = );

proc sql noprint;

create table rc_count_table as 
select 
	&scaleVar.
from 
	&rawDataSet;

quit;

proc sql noprint;

select 
	count(*)
	into: rc_count
from 
	rc_count_table;

quit;

%let rc_count = &rc_count.;

proc sql noprint;
	select &scaleVar.
	into :var1-:var&rc_count.
	from rc_count_table;
quit;

%put bbbb &var1 &var2 &var3 &var4 &var5 &var6;

proc sql;

create table cumDR_graph_1 as 
select 
		&scaleVar.,
		%do yearIdx = 1 %to &yearCnt; 
						%if "&yearIdx" = "&yearCnt" %then &actualVar._&yearIdx.;
						%else &actualVar._&yearIdx.,; 
					%end;
from 
	&rawDataSet;
quit;

proc sql;
create table cumPD_graph as 
select 
		&scaleVar.,
		%do yearIdx = 1 %to &yearCnt; 
						%if "&yearIdx" = "&yearCnt" %then &outputVar._&yearIdx.;
						%else &outputVar._&yearIdx.,; 
					%end;
from 
	&rawDataSet;
quit;



data rc_count_table;
set rc_count_table;
new_rc = 'RC_' || put(_n_,best8. -L);
run;

data rc_count_table;
set rc_count_table;
new_rc_2 = 'RC_2_' || put(_n_,best8. -L);
run;

proc sql;
insert into cumDR_graph_1
	values ( "YEAR", %do yearIdx = 1 %to &yearCnt; 
					%if "&yearIdx" =  "&yearCnt" %then %sysevalf(&yearIdx. - 0.0);
					%else %sysevalf(&yearIdx. - 0.0),;
					%end;);
quit;

proc sql;
create table table_new_rc as 
select 
	*
from 
	rc_count_table as a
	left join cumDR_graph_1 as b
		on a.&scaleVar. = b.&scaleVar.;
quit;

proc sql;
insert into table_new_rc
	values ( "YEAR", "YEAR", "YEAR", %do yearIdx = 1 %to &yearCnt; 
					%if "&yearIdx" =  "&yearCnt" %then %sysevalf(&yearIdx. - 0.0);
					%else %sysevalf(&yearIdx. - 0.0),;
					%end;);
quit;

proc transpose data = table_new_rc out = table_new_rc_2;
id  new_rc;
run;


proc sql;
insert into cumPD_graph
	values ( "YEAR", %do yearIdx = 1 %to &yearCnt; 
					%if "&yearIdx" =  "&yearCnt" %then %sysevalf(&yearIdx. - 0.0);
					%else %sysevalf(&yearIdx. - 0.0),;
					%end;);
quit;

proc sql;
create table table_new_rc_v2 as 
select 
	*
from 
	rc_count_table as a
	left join cumPD_graph as b
		on a.&scaleVar. = b.&scaleVar.;
quit;

proc sql;
insert into table_new_rc_v2
	values ( "YEAR", "YEAR", "YEAR", %do yearIdx = 1 %to &yearCnt; 
					%if "&yearIdx" =  "&yearCnt" %then %sysevalf(&yearIdx. - 0.0);
					%else %sysevalf(&yearIdx. - 0.0),;
					%end;);
quit;

proc transpose data = table_new_rc_v2 out = table_new_rc_v2_2;
id  new_rc_2;
run;

proc sql;
create table table_all_values as
select * 
from table_new_rc_2 as a
left join table_new_rc_v2_2 as b
on a.YEAR = b.YEAR;
quit;

%let color_1 =BLUE;
%let color_2 =RED;
%let color_3 =GREEN;
%let color_4 =BROWN;
%let color_5 =YELLOW;
%let color_6 =PURPLE;
%let color_7 =GRAY;
%let color_8 =ORANGE;
%let color_9 =turquoise;
%let color_10 =pink;


proc sgplot data=table_all_values;
Title h=12pt justify=left "TTC LtPD, макропродукт «"&product_name"» ";
		%do yearIdx = 1 %to &rc_count; 
					series x=YEAR y=RC_2_&yearIdx. /LINEATTRS=(color=&&color_&yearIdx)
													CURVELABEL= "&&var&yearIdx."
													CURVELABELLOC=OUTSIDE;
					scatter x=YEAR y=RC_&yearIdx./ 
												MARKERATTRS=(color=&&color_&yearIdx
															symbol=CircleFilled)
												LEGENDLABEL= "&actualVar._&yearIdx.";
					yaxis LABEL="Probability" max= 1;
					%end;

run;


%mend m_graph_relative;



%macro m_LTPD_TESTS(rawDataSet=, actualVar=, outputVar=, modelId=, modelDesc=, scaleVar=, thresholdSet=);

proc sql noprint;
create table rc_table as 
select &scaleVar
from &rawDataSet;
quit;


proc transpose  data = &rawDataSet out = count_table ;
id  &scaleVar;
run;

proc sql noprint;

SELECT 
	count(*)
	into: yearCnt
FROM 
	count_table
WHERE 
	_NAME_ LIKE "&actualVar.%";

QUIT;

proc sql noprint;

SELECT 
	yellow_threshold
	into: yellow_threshold
FROM 
	&thresholdSet
WHERE MACRO_NAME = "m_r_squared_PD_IFRS9";

QUIT;

proc sql noprint;

SELECT 
	red_threshold
	into: red_threshold
FROM 
	&thresholdSet
WHERE MACRO_NAME = "m_r_squared_PD_IFRS9";

QUIT;


%m_r_squared_PD_IFRS9(rawDataSet = &rawDataSet, actualVar = &actualVar, outputVar = &outputVar, yearCnt = &yearCnt,yellowThreshold = &yellow_threshold, redThreshold= &red_threshold, product_name= &modelDesc, scaleVar = &scaleVar);

proc sql noprint;

SELECT 
	yellow_threshold
	into: yellow_threshold
FROM 
	&thresholdSet
WHERE MACRO_NAME = "m_RMSE_PD_IFRS9";

QUIT;

proc sql noprint;

SELECT 
	red_threshold
	into: red_threshold
FROM 
	&thresholdSet
WHERE MACRO_NAME = "m_RMSE_PD_IFRS9";

QUIT;

%if "&modelID" ^= "IFRS9_0104"
%then %m_RMSE_PD_IFRS9(rawDataSet = &rawDataSet, actualVar = &actualVar, outputVar = &outputVar, yearCnt = &yearCnt,yellowThreshold = &yellow_threshold, redThreshold= &red_threshold, product_name= &modelDesc, scaleVar = &scaleVar);

proc sql noprint;

SELECT 
	yellow_threshold
	into: yellow_threshold
FROM 
	&thresholdSet
WHERE MACRO_NAME = "m_RMSD_PD_IFRS9";

QUIT;

proc sql noprint;

SELECT 
	red_threshold
	into: red_threshold
FROM 
	&thresholdSet
WHERE MACRO_NAME = "m_RMSD_PD_IFRS9";

QUIT;

/*%if &modelID IN (%str(IFRS9_0101), %str(IFRS9_0102), %str(IFRS9_0103))*/
%if "&modelId" = "IFRS9_0101" OR "&modelId" = "IFRS9_0102" OR "&modelId" = "IFRS9_0103"
%then %m_RMSD_PD_IFRS9(rawDataSet = &rawDataSet, actualVar = &actualVar, outputVar = &outputVar, yearCnt = &yearCnt,yellowThreshold = &yellow_threshold, redThreshold= &red_threshold, product_name= &modelDesc, scaleVar = &scaleVar);

proc sql noprint;

SELECT 
	yellow_threshold
	into: yellow_threshold
FROM 
	&thresholdSet
WHERE MACRO_NAME = "m_relative_PD_IFRS9";

QUIT;

proc sql noprint;

SELECT 
	red_threshold
	into: red_threshold
FROM 
	&thresholdSet
WHERE MACRO_NAME = "m_relative_PD_IFRS9";

QUIT;

%m_relative_PD_IFRS9(rawDataSet = &rawDataSet, actualVar = &actualVar, outputVar = &outputVar, yearCnt = &yearCnt,yellowThreshold = &yellow_threshold, redThreshold= &red_threshold, product_name= &modelDesc, scaleVar = &scaleVar);

%m_graph_cDR(rawDataSet = &rawDataSet, actualVar = &actualVar, outputVar = &outputVar, yearCnt = &yearCnt, product_name= &modelDesc, scaleVar = &scaleVar);

%m_graph_cPD(rawDataSet = &rawDataSet, actualVar = &outputVar, outputVar = &actualVar, yearCnt = &yearCnt, product_name= &modelDesc, scaleVar = &scaleVar);

%m_graph_relative(rawDataSet = &rawDataSet, actualVar = &outputVar, outputVar = &actualVar, yearCnt = &yearCnt, product_name= &modelDesc, scaleVar = &scaleVar);



%mend m_LTPD_TESTS;
%macro m_get_simple_modif_gini(rawDataSet=, outputVar=0, actualVar=, actualVarEAD=0, inputVarList=);
	/* 
		Назначение: Расчет коэффициента Джини для каждой переменной из inputVarList.
	   
		Параметры:  rawDataSet	 - Имя входного набора.
					outputVar	 - Имя выходной переменной модели.
								   Значение по умолчанию = 0.
				    actualVar	 - Имя фактической переменной LGD.
					actualVarEAD - Имя фактической переменной EAD.
								   Значение по умолчанию = 0.
				    inputVarList - Строка, содержащая перечень имен переменных, разделитель - '|'.
								   Пример: variable1|variable2|variable3.
									
		Выходная таблица:		 - OUTPUT_M_GET_SIMPLE_MODIF_GINI
								   (
									variable1 float,
									variable2 float,
									variable3 float,
									...
								   )
								   Выходная таблица содержит одну строку:
								   значение коэффициента Джини для каждой переменной из inputVarList.
								   
		Результат работы:
					Если указаны outputVar и actualVarEAD, а также outputVar входит в список переменных inputVarList,
						то Джини для outputVar будет рассчитан со взвешиванием на EAD.
					Иначе все переменные из inputVarList считаются без взвешивания.
	*/
	   
	*** Определение количества входных переменных;
	%let inputVarCnt=%SYSFUNC(countw(&inputVarList.,%STR('|')));
	
	*** Копирование исходного набора, чтобы избежать изменений;
	data INPUT_SET;
		set &rawDataSet.;
		where &actualVar. ^= .;
	run;
	
	*** Цикл по входным переменным;
	%do varIdx=1 %to &inputVarCnt.;
		%let inputVar=%SCAN(%STR(&inputVarList.),&varIdx.,'|');
		
		*** Для выходной переменной модели рассчет производится с взвешиванием на EAD;
		%if "&inputVar." = "&outputVar." %then %do;
			data INPUT_SIMPLE (keep= &inputVar. &actualVar. &actualVarEAD. loss);
				set INPUT_SET;
				where &inputVar. ^= . and &actualVarEAD. ^= .;
				loss = &actualVar. * &actualVarEAD.;
			run;
			
			%let giniVar = loss;
			%let weightVar = &actualVarEAD.;
		%end;
		%else %do;
			data INPUT_SIMPLE (keep= &inputVar. &actualVar. const_one);
				set INPUT_SET;
				where &inputVar. ^= .;
				const_one = 1;
			run;
			
			%let giniVar = &actualVar.;
			%let weightVar = const_one;
		%end;
		
		*** Расчет сумм весовой переменной и переменной Джини;
		proc sql noprint;
			select
				sum(&weightVar.),sum(&giniVar.)
			into :sumWeightVar, :sumGiniVar
			from INPUT_SIMPLE;
		quit;
		
		*** Расчет значения идеальной прощади areaIdeal;
		proc sort data=INPUT_SIMPLE out=SORT_BY_ACTUAL_VAR (keep=&giniVar. &weightVar.);
			by descending &actualVar.;
		run;
		
		data SORT_BY_ACTUAL_VAR (keep=cumulative_gini_var_pct cumulative_gini_var_pct_lag &weightVar.);
			set SORT_BY_ACTUAL_VAR;
			retain cumulative_gini_var_pct;
			cumulative_gini_var_pct + &giniVar. / &sumGiniVar.;
			cumulative_gini_var_pct_lag = lag1(cumulative_gini_var_pct);
		run;
		
		proc sql noprint;
			select sum(0.5 * (cumulative_gini_var_pct + cumulative_gini_var_pct_lag) * &weightVar.) / &sumWeightVar. - 0.5
			into :areaIdeal_&varIdx.
			from SORT_BY_ACTUAL_VAR;
		quit;
		
		*** Расчет площади для переменной;
		proc sort data=INPUT_SIMPLE out=SORT_BY_INPUT_VAR (keep=&giniVar. &weightVar.);
			by descending &inputVar.;
		run;

		data SORT_BY_INPUT_VAR (keep=cumulative_gini_var_pct cumulative_gini_var_pct_lag &weightVar.);
			set SORT_BY_INPUT_VAR;
			retain cumulative_gini_var_pct;
			cumulative_gini_var_pct + &giniVar. / &sumGiniVar.;
			cumulative_gini_var_pct_lag = lag1(cumulative_gini_var_pct);
		run;

		proc sql noprint;
			select sum(0.5 * (cumulative_gini_var_pct + cumulative_gini_var_pct_lag) * &weightVar.) / &sumWeightVar. - 0.5
			into :area_&varIdx.
			from SORT_BY_INPUT_VAR;
		quit;	
	%end;
	
	*** Создание итогового набора данных;
	data OUTPUT_M_GET_SIMPLE_MODIF_GINI;
		%do varIdx=1 %to &inputVarCnt.;
			%SCAN(%STR(&inputVarList.),&varIdx.,'|') = &&area_&varIdx. / &&areaIdeal_&varIdx.;
		%end;
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_SET SORT_BY_ACTUAL_VAR SORT_BY_INPUT_VAR INPUT_SIMPLE;
	run;

%mend m_get_simple_modif_gini;

/*%m_get_simple_modif_gini(rawDataSet=lgd_test_full, outputVar=0, actualVar=rr_actual, actualVarEAD=0, inputVarList=rr_model);*/

%macro m_print_modif_gini(rawValDataSet=, rawDevDataSet=, outputVar=, actualVar=, actualVarEAD=0, inputVarList=0,
						  factorLabelSet=0, yellowFactorThreshold=0.1, redFactorThreshold=0.05, yellowModelThreshold=0.3, redModelThreshold=0.15,
						  yellowRelativeThreshold=0.05, redRelativeThreshold=0.1);
	/* 
		Назначение: Расчет модифицированного коэффициента Джини для входных переменных в разрезе периодов,
					расчет модифицированного коэффициента Джини для выходной переменной в разрезе периодов.
	   
		Параметры:  rawValDataSet   - Имя выборки для валидации.
					rawDevDataSet   - Имя выборки для разработки.
					outputVar	    - Имя выходной переменной модели.
					actualVar		- Имя фактической переменной LGD.
					actualVarEAD	- Имя фактической переменной EAD.
									  Значение по умолчанию = 0.
									  При нуле, взвешивание выходной переменной на EAD не производится.
					inputVarList    - Строка, содержащая перечень имен входных переменных, разделитель - '|'.
								      Пример: variable1|variable2|variable3.
									  Значение по умолчанию = 0. В этом случае Джини считается только для выходной переменной.
					factorLabelSet	- Набор данных, содержащий лейблы для факторов.
									  Должен содержать следующий набор полей:
											factor character			- название фактора,
											factor_label character		- лейбл фактора.
									  Значение по умолчанию = 0, в этом случае лейблы не используются.
					yellowFactorThreshold	- Желтое пороговое значение для факторов.
											  Значение по умолчанию = 0,1.
					redFactorThreshold		- Красное пороговое значение для факторов.
											  Значение по умолчанию = 0,05.
					yellowModelThreshold	- Желтое пороговое значение для модели.
											  Значение по умолчанию = 0,3.
					redModelThreshold		- Красное пороговое значение для модели.
											  Значение по умолчанию = 0,15.
					yellowRelativeThreshold - Относительное желтое пороговое значение.
											  Значение по умолчанию = 0,05.
					redRelativeThreshold	- Относительное красное пороговое значение.
											  Значение по умолчанию = 0,1.
								   
		Вызываемые макросы:
					m_get_simple_modif_gini	 - Расчет модифицированного коэффициента Джини для одного периода,
											   выходная таблица - OUTPUT_M_GET_SIMPLE_MODIF_GINI.
											   
		Результат работы:
					Если указана переменная actualVarEAD, то outputVar взвешивается на EAD.
					Если указана переменная inputVarList, то сначала выводится результат для каждой переменной из списка,
						а затем отдельная таблица для outputVar.
	*/
	
	*** Количество итераций при расчете модифицированного коэффициента Джини;
	%let iterationNum = 10;
	
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	%if "&inputVarList." = "0" %then %do;
		%let sumVarList = &outputVar.;
	%end;
	%else %do;
		%let sumVarList = &inputVarList.|&outputVar.;
	%end;
	
	*** Определение количества входных переменных;
	%let sumVarCnt=%SYSFUNC(countw(&sumVarList.,%STR('|')));
	
	%if "&actualVarEAD." = "0" %then %do;
		%let keepVars = &actualVar.;
		%let simpleGiniInputVars = actualVar=&actualVar., inputVarList=&sumVarList.;
	%end;
	%else %do;
		%let keepVars = &actualVar. &actualVarEAD.;
		%let simpleGiniInputVars = outputVar=&outputVar., actualVar=&actualVar., actualVarEAD=&actualVarEAD., inputVarList=&sumVarList.;
	%end;
	
	*** Копирование исходного набора, чтобы избежать изменений;
	data INPUT_1;
		set &rawDevDataSet. (keep= &keepVars.
							%do varIdx=1 %to &sumVarCnt.;
								%SCAN(%STR(&sumVarList.),&varIdx.,'|')
							%end;
							);
	run;
	
	data INPUT_2;
		set &rawValDataSet. (keep= &keepVars.
							%do varIdx=1 %to &sumVarCnt.;
								%SCAN(%STR(&sumVarList.),&varIdx.,'|')
							%end;
							);
	run;
	
	*** Цикл по периодам;
	%do idx=1 %to 2;
		
		*** Расчет модифицированного коэффициента Джини;
		%m_get_simple_modif_gini(rawDataSet=INPUT_&idx., &simpleGiniInputVars.);
		
		proc transpose data=OUTPUT_M_GET_SIMPLE_MODIF_GINI
						out=GINI_VALUE;
		run;
		
		*** Создание таблицы для хранения результатов итераций;
		proc sql;
			create table RESULT_ITERATION 
			(
				%do varIdx=1 %to &sumVarCnt.;
					%SCAN(%STR(&sumVarList.), &varIdx.,'|') float format percentn7.2
					%if &varIdx. < &sumVarCnt. %then
						,
					;
				%end;
			);
		quit;
		
		*** Цикл для расчета доверительных интервалов модифицированного коэффициента Джини;
		%do iterIdx=1 %to &iterationNum.;
		
			*** Создание случайной выборки (с равной вероятностью и с повторениями), размер как у исходного набора;
			proc surveyselect data=INPUT_&idx.
								method=urs
								samprate=1
								outhits
								out=SAMPLE_SET noprint;
			run;
			
			*** Расчет модифицированного коэффициента Джини для одной итерации;
			%m_get_simple_modif_gini(rawDataSet=SAMPLE_SET, &simpleGiniInputVars.);
			
			*** Вставка в таблицу RESULT_ITERATION;
			proc sql;
				insert into RESULT_ITERATION
				(
					%do varIdx=1 %to &sumVarCnt.;
						%SCAN(%STR(&sumVarList.), &varIdx.,'|')
						%if &varIdx. < &sumVarCnt. %then
							,
						;
					%end;
				)
				select
					%do varIdx=1 %to &sumVarCnt.;
						%SCAN(%STR(&sumVarList.), &varIdx.,'|')
						%if &varIdx. < &sumVarCnt. %then
							,
						;
					%end;
				from OUTPUT_M_GET_SIMPLE_MODIF_GINI; 
			quit;
			
			*** Удаление лишних наборов данных;
			proc datasets nolist;
				delete SAMPLE_SET OUTPUT_M_GET_SIMPLE_MODIF_GINI;
			run;
		%end;
		
		*** Расчет 5-го и 95-го процентилей для каждой переменной;
		proc stdize data=RESULT_ITERATION
					PctlMtd=ord_stat
					outstat=GINI_CONFIDENCE_LEVELS
					out=DATA1
					pctlpts=5, 95;
			var
				%do varIdx=1 %to &sumVarCnt.;
					%SCAN(%STR(&sumVarList.),&varIdx.,'|')
				%end;
				;
		run;
		
		data GINI_CONFIDENCE_LEVELS;
			set GINI_CONFIDENCE_LEVELS;
			where _type_ =: 'P';
		run;
		
		proc sort data=GINI_CONFIDENCE_LEVELS;
			by _type_;
		run;
		
		proc transpose data=GINI_CONFIDENCE_LEVELS
						out=GINI_CONFIDENCE_LEVELS;
		run;
		
		*** Создание итоговой таблицы для периода;
		proc sql;
			create table GINI_BY_FACTOR_&idx. as
			select conf._NAME_ as factor,
				conf.Col1 as gini_lower format percentn7.2,
				gini.Col1 as gini_value format percentn7.2,
				conf.Col2 as gini_upper format percentn7.2
			from GINI_CONFIDENCE_LEVELS as conf
			inner join GINI_VALUE as gini
				on conf._NAME_ = gini._NAME_;
		quit;
	%end;
	
	*** Создание итоговой таблицы;
	proc sql;
		create table OUTPUT_M_GET_MODIF_GINI as
		select dev.factor,
			dev.gini_value as gini_dev,
			dev.gini_lower as gini_lower_dev,
			dev.gini_upper as gini_upper_dev,
			val.gini_value as gini_val,
			val.gini_lower as gini_lower_val,
			val.gini_upper as gini_upper_val,
			(val.gini_value - dev.gini_value) / dev.gini_value as diff format percentn7.2,
			case when abs(calculated diff) > &redRelativeThreshold. then "красный"
				when abs(calculated diff) > &yellowRelativeThreshold. then "желтый"
				else "зеленый" end as light_rel
		from GINI_BY_FACTOR_1 as dev
		inner join GINI_BY_FACTOR_2 as val
			on dev.factor=val.factor;
	quit;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete DATA1 GINI_VALUE GINI_CONFIDENCE_LEVELS RESULT_ITERATION
			%do idx=1 %to 2;
				INPUT_&idx. GINI_BY_FACTOR_&idx.
			%end;
			;
	run;
	
	
	***																										  ;
	*** Расчет модифицированного коэффициента Джини для факторов модели на выборках для разработки и валидации;
	***																										  ;
	
	%if "&inputVarList." ^= "0" %then %do;
		data GINI_INPUT_VARS;
			set OUTPUT_M_GET_MODIF_GINI;
			where factor ^= "&outputVar.";
			format light_dev light_val $30.;
			
			old_gini_lower_dev = gini_lower_dev;
			old_gini_upper_dev = gini_upper_dev;
			if gini_dev < 0 then do;
				gini_dev = abs(gini_dev);
				gini_lower_dev = -1 * old_gini_upper_dev;
				gini_upper_dev = -1 * old_gini_lower_dev;
			end;
			select;
				when (gini_lower_dev < &redFactorThreshold.)	light_dev = "красный";
				when (gini_lower_dev < &yellowFactorThreshold.) light_dev = "желтый";
				otherwise										light_dev = "зеленый";
			end;
			
			old_gini_lower_val = gini_lower_val;
			old_gini_upper_val = gini_upper_val;
			if gini_val < 0 then do;
				gini_val = abs(gini_val);
				gini_lower_val = -1 * old_gini_upper_val;
				gini_upper_val = -1 * old_gini_lower_val;
			end;
			select;
				when (gini_lower_val < &redFactorThreshold.)	light_val = "красный";
				when (gini_lower_val < &yellowFactorThreshold.) light_val = "желтый";
				otherwise										light_val = "зеленый";
			end;
		run;
		
		*** Выбор лейбла фактора;
		%if "&factorLabelSet." = "0" %then %do;
			data REPORT_SET_GINI_INPUT;
				set GINI_INPUT_VARS;
				rename factor = factor_label;
			run;
		%end;
		%else %do;
			proc sql noprint;
				create table REPORT_SET_GINI_INPUT as
				select a.*,
					trim(a.factor) || ': ' || trim(b.factor_label) as factor_label
				from GINI_INPUT_VARS as a
				left join &factorLabelSet. as b
					on upcase(a.factor) = upcase(b.factor);
			quit;
		%end;
	
		Title3 h=12pt justify=left "Расчет модифицированного коэффициента Джини для факторов модели на выборках для разработки и валидации";
		Title4 h=12pt justify=left
		"Абсолютное значение. Желтая зона: %sysfunc(putn(&redFactorThreshold., percentn7.2)) - %sysfunc(putn(&yellowFactorThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redFactorThreshold., percentn7.2)).";
		Title5 h=12pt justify=left
		"Относительная разница. Желтая зона: %sysfunc(putn(&yellowRelativeThreshold., percentn7.2)) - %sysfunc(putn(&redRelativeThreshold., percentn7.2)), красная зона: >%sysfunc(putn(&redRelativeThreshold., percentn7.2)).";
		Title6 h=12pt "Выборка для разработки";
		
		proc report data=REPORT_SET_GINI_INPUT SPLIT='';
			column factor_label gini_dev gini_lower_dev gini_upper_dev light_dev;
			define factor_label /	display "Фактор"
									style(column)=[fontsize=1]
									style(header)=[fontsize=1];
			define gini_dev /	display "Джини"
								style(header)=[fontsize=1];
			define gini_lower_dev / display "Нижняя граница"
									style(header)=[fontsize=1];
			define gini_upper_dev / display "Верхняя граница"
									style(header)=[fontsize=1];
			define light_dev /	display "Светофор"
								style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
								style(header)=[fontsize=1];
		run;
		
		Title1;
		
		Title6 h=12pt "Выборка для валидации";
		
		proc report data=REPORT_SET_GINI_INPUT SPLIT='';
			column factor_label gini_val gini_lower_val gini_upper_val light_val diff light_rel;
			define factor_label /	display "Фактор"
									style(column)=[fontsize=1]
									style(header)=[fontsize=1];
			define gini_val /	display "Джини"
								style(header)=[fontsize=1];
			define gini_lower_val / display "Нижняя граница"
									style(header)=[fontsize=1];
			define gini_upper_val / display "Верхняя граница"
									style(header)=[fontsize=1];
			define light_val /	display "Светофор, абсолютное значение"
								style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
								style(header)=[fontsize=1];
			define diff /	display "Относительная разница(%)"
							style(header)=[fontsize=1];
			define light_rel /	display "Светофор, относительная разница"
								style(column)=[backgroundcolor=$BACKCOLOR_FMT.]
								style(header)=[fontsize=1];
		run;
		
		Title1;
	%end;
	
	
	***																									   ;
	*** Расчет модифицированного коэффициента Джини на уровне модели на выборках для разработки и валидации;
	***																									   ;
	
	data REPORT_SET_GINI_OUTPUT;
		set OUTPUT_M_GET_MODIF_GINI;
		where factor = "&outputVar.";
		format light_dev light_val $30.;
		select;
			when (gini_lower_dev < &redModelThreshold.)	   light_dev = "красный";
			when (gini_lower_dev < &yellowModelThreshold.) light_dev = "желтый";
			otherwise									   light_dev = "зеленый";
		end;
		
		select;
			when (gini_lower_val < &redModelThreshold.)	   light_val = "красный";
			when (gini_lower_val < &yellowModelThreshold.) light_val = "желтый";
			otherwise									   light_val = "зеленый";
		end;
	run;
	
	Title3 h=12pt justify=left "Расчет модифицированного коэффициента Джини на уровне модели на выборках для разработки и валидации";
	Title4 h=12pt justify=left
	"Абсолютное значение. Желтая зона: %sysfunc(putn(&redModelThreshold., percentn7.2)) - %sysfunc(putn(&yellowModelThreshold., percentn7.2)), красная зона: <%sysfunc(putn(&redModelThreshold., percentn7.2)).";
	Title5 h=12pt justify=left
	"Относительная разница. Желтая зона: %sysfunc(putn(&yellowRelativeThreshold., percentn7.2)) - %sysfunc(putn(&redRelativeThreshold., percentn7.2)), красная зона: >%sysfunc(putn(&redRelativeThreshold., percentn7.2)).";
	
	proc print data= REPORT_SET_GINI_OUTPUT noobs label;
		var gini_dev gini_lower_dev gini_upper_dev;
		var light_dev / style(data)=[background=$BACKCOLOR_FMT.];
		var gini_val gini_lower_val gini_upper_val;
		var light_val / style(data)=[background=$BACKCOLOR_FMT.];
		var diff;
		var light_rel / style(data)=[background=$BACKCOLOR_FMT.];
		label   gini_dev="Джини, разработка"
				gini_lower_dev="Нижняя граница, разработка"
				gini_upper_dev="Верхняя граница, разработка"
				light_dev="Светофор, разработка"
				gini_val="Джини, валидация"
				gini_lower_val="Нижняя граница, валидация"
				gini_upper_val="Верхняя граница, валидация"
				light_val="Светофор, валидация"
				diff="Относительная разница(%)"
				light_rel="Светофор, относительная разница";
	run;
	
	Title1;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete GINI_INPUT_VARS GINI_OUTPUT_VAR OUTPUT_M_GET_MODIF_GINI REPORT_SET_GINI_OUTPUT REPORT_SET_GINI_INPUT;
	run;

%mend m_print_modif_gini;



/*%m_print_modif_gini(rawValDataSet=lgd_test, rawDevDataSet=lgd_test, outputVar=rr_actual, actualVar=rr_model, actualVarEAD=0, inputVarList=0,
						  factorLabelSet=0, yellowFactorThreshold=0.1, redFactorThreshold=0.05, yellowModelThreshold=0.3, redModelThreshold=0.15,
						  yellowRelativeThreshold=0.05, redRelativeThreshold=0.1);*/

%macro m_roc_curve(rawDataSet=, inputVar=, actualVar=, periodVar=, periodLabelVar=);
	/* 
		Назначение: Построение ROC-кривой для каждого входного периода.
	   
		Параметры:  rawDataSet     - Имя входного набора данных.
					inputVar	   - Имя входной переменной.
					actualVar	   - Имя бинарной фактической переменной.
					periodVar	   - Имя переменной, определяющей период.
					periodLabelVar - Имя переменной, определяющей текстовую метку периода.
	*/
	
	**** Определение периодов; 
	proc sql noprint;
		create table PERIOD_LIST as
		select distinct &periodVar., &periodLabelVar.
		from &rawDataSet.
		order by &periodVar.;
		
		select count(*)
		into :periodCnt
		from PERIOD_LIST;
	quit;
	
	%let periodCnt = &periodCnt.;
	
	proc sql noprint;
		select &periodVar.
		into :period1-:period&periodCnt.
		from PERIOD_LIST;
		
		select &periodLabelVar.
		into :periodLabelRoc1-:periodLabelRoc&periodCnt.
		from PERIOD_LIST;
	quit;
		
	%do periodNum = 1 %to &periodCnt.;
		data INPUT_ROC;
			set &rawDataSet.;
			where &periodVar. = &&period&periodNum. and &inputVar. ^= . and &actualVar. ^= .;
			keep &inputVar. &actualVar.;
		run;

		proc sort data=INPUT_ROC;
			by descending &inputVar.;
		run;

		proc sort data=INPUT_ROC out=INPUT_ROC_SORTED;
			by descending &actualVar.;
		run;

		data INPUT_ROC_SORTED;
			set INPUT_ROC_SORTED (keep=&actualVar.);
			rename &actualVar. = actualVarSorted;
		run;

		proc sql noprint;
			select count(*), sum(&actualVar.)
			into :totalCount, :actualVarSum
			from INPUT_ROC;
		quit;
		
		*** Расчет значений, необходимых для построения отчета;
		data REPORT_SET_&periodNum.;
			set INPUT_ROC;
			set INPUT_ROC_SORTED;
			actualVarPercent = &actualVar. / &actualVarSum.;
			actualVarSortedPercent = actualVarSorted / &actualVarSum.;
			retain actualVarPercentCum actualVarSortedPercentCum;
			segmentArea = 0.5 * (actualVarPercentCum * 2 + actualVarPercent) / &totalCount.;
			segmentAreaIdeal = 0.5 * (actualVarSortedPercentCum * 2 + actualVarSortedPercent) / &totalCount.;
			actualVarPercentCum + actualVarPercent;
			actualVarSortedPercentCum + actualVarSortedPercent;
			totalPercent = _N_ / &totalCount.;
			keep totalPercent actualVarSortedPercentCum actualVarPercentCum;
		run;
	%end;

data REPORT_SET;
		set
			%do periodNum=1 %to &periodCnt.;
				REPORT_SET_&periodNum.(rename=(totalPercent=totalPercent_&periodNum.
												actualVarSortedPercentCum=actualVarSortedPercentCum_&periodNum.
												actualVarPercentCum=actualVarPercentCum_&periodNum.))
			%end;
			;
	run;

	proc sgplot data= REPORT_SET;
		%do periodNum=1 %to &periodCnt.;
			series x=totalPercent_&periodNum. y=actualVarSortedPercentCum_&periodNum. / legendlabel = "Идеальная кривая, &&periodLabelRoc&periodNum."
																						lineattrs = (pattern=4);
			series x=totalPercent_&periodNum. y=actualVarPercentCum_&periodNum. / legendlabel = "ROC-кривая, &&periodLabelRoc&periodNum.";
		%end;
		series x=totalPercent_1 y=totalPercent_1 / legendlabel = 'x = y' lineattrs = (color=black);
		
		xaxis display=(noline noticks nolabel);
		yaxis display=(noline noticks nolabel);
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_ROC INPUT_ROC_SORTED REPORT_SET PERIOD_LIST
			%do periodNum=1 %to &periodCnt.;
				REPORT_SET_&periodNum.
			%end;
			;
	run;

%mend m_roc_curve;


%macro m_loss_shortfall(rawDataSet=, outputVar=, actualVar=, actualVarEAD=, periodVar=, periodLabelVar=, yellowThreshold=0.1, redThreshold=0.2);
	/* 
		Назначение: Расчет коэффициента Loss Shortfall в разрезе периодов.
		
		Параметры:  rawDataSet      - Имя входного набора данных.
					outputVar	    - Имя выходной переменной модели.
					actualVar	    - Имя фактической переменной.
					actualVarEAD    - Имя фактической переменной EAD.
					periodVar       - Имя переменной, определяющей период.
					periodLabelVar  - Имя переменной, определяющей текстовую метку периода.
					yellowThreshold - Желтое пороговое значение.
									  Значение по умолчанию = 0,1.
					redThreshold 	- Красное пороговое значение.
									  Значение по умолчанию = 0,2.
	*/
	
	proc format;
		value $BACKCOLOR_FMT "зеленый"="vlig"
							  "желтый"="yellow"
							 "красный"="salmon";
	run;
	
	*** Удаление периода разработки, расчет потерь;
	data INPUT_VALIDATION;
		set &rawDataSet.;
		where &outputVar. ^= . and &actualVar. ^= .;
		loss_predicted = &outputVar. * &actualVarEAD.;
		loss_actual = &actualVar. * &actualVarEAD.;
		keep &periodVar. &periodLabelVar. loss_predicted loss_actual;
	run;
	
	*** Расчет коэффициента Loss Shortfall;
	proc sql noprint;
		create table RESULT_SET_LSH as
		select &periodVar.,
				&periodLabelVar.,
				sum(loss_predicted) as summ_loss_predicted,
				sum(loss_actual) as summ_loss_actual
		from INPUT_VALIDATION
		group by &periodVar., &periodLabelVar.
		order by &periodVar.;
	quit;
	
	data RESULT_SET_LSH;
		set RESULT_SET_LSH;
		format loss_shortfall 9.2 light $30.;
		loss_shortfall = 1 - (summ_loss_predicted / summ_loss_actual);
		select;
			when (abs(loss_shortfall) > &redThreshold.)	   light = "красный";
			when (abs(loss_shortfall) > &yellowThreshold.) light = "желтый";
			otherwise									   light = "зеленый";
		end;
	run;
	
	*** Вывод результатов;
	proc print data=RESULT_SET_LSH noobs label;
		var &periodLabelVar. loss_shortfall;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label	&periodLabelVar. = "Период валидации"
				loss_shortfall = "Loss Shortfall"
				light = "Светофор";
	run;
	
	*** Удаление лишних наборов данных;
	proc datasets nolist;
		delete INPUT_VALIDATION RESULT_SET_LSH;
	run;

%mend m_loss_shortfall;


%macro m_lgd_SME_PS (rawDataSet=, recoveryModelVar=, defaultModelVar=, cureModelVar=, 
						period=, period_label=);

proc sql;
create table rawDevDataSet as 
select *
from &rawDataSet
where period = 1;
create table rawValDataSet as
select *
from &rawDataSet
where period = 2;
quit;

Title h=12pt justify=center "Коэффициент Джини модифицированный (на уровне модели уровня возмещения)";
%m_print_modif_gini(rawValDataSet=rawValDataSet, rawDevDataSet=rawDevDataSet, outputVar=&recoveryModelVar._mod, actualVar=&recoveryModelVar._act, actualVarEAD=0, inputVarList=0,
						  factorLabelSet=0, yellowFactorThreshold=0.1, redFactorThreshold=0.05, yellowModelThreshold=0.3, redModelThreshold=0.15,
						  yellowRelativeThreshold=0.05, redRelativeThreshold=0.1);

Title h=12pt justify=center "CAP-кривая на выборке для количественного тестирования для модели уровня возмещения";
%m_roc_curve(rawDataSet=rawValDataSet, inputVar=&recoveryModelVar._mod, actualVar=&recoveryModelVar._act, periodVar=&period, periodLabelVar=&period_label);

Title h=12pt justify=center "Коэффициент Джини модифицированный (на уровне модели уровня потерь в случае дефолта)";
%m_print_modif_gini(rawValDataSet=rawValDataSet, rawDevDataSet=rawDevDataSet, outputVar=&defaultModelVar._mod, actualVar=&defaultModelVar._act, actualVarEAD=0, inputVarList=0,
						  factorLabelSet=0, yellowFactorThreshold=0.1, redFactorThreshold=0.05, yellowModelThreshold=0.3, redModelThreshold=0.15,
						  yellowRelativeThreshold=0.05, redRelativeThreshold=0.1);
Title h=12pt justify=center "CAP-кривая на выборке для количественного тестирования для модели уровня потерь в случае дефолта";
%m_roc_curve(rawDataSet=rawValDataSet, inputVar=&defaultModelVar._mod, actualVar=&defaultModelVar._act, periodVar=&period, periodLabelVar=&period_label);
Title h=12pt justify=left "Значение коэффицента Loss shortfall (на уровне модели уровня потерь в случае дефолта)";

%m_loss_shortfall(rawDataSet=rawValDataSet, outputVar=&defaultModelVar._mod, actualVar=&defaultModelVar._act, actualVarEAD=EAD, periodVar=&period, periodLabelVar=&period_label, yellowThreshold=0.1, redThreshold=0.2);


Title h=12pt justify=center "Коэффициент Джини модифицированный (на уровне модели вероятности выздоровления)";
%m_print_modif_gini(rawValDataSet=rawValDataSet, rawDevDataSet=rawDevDataSet, outputVar=&cureModelVar._mod, actualVar=&cureModelVar._act, actualVarEAD=0, inputVarList=0,
						  factorLabelSet=0, yellowFactorThreshold=0.1, redFactorThreshold=0.05, yellowModelThreshold=0.3, redModelThreshold=0.15,
						  yellowRelativeThreshold=0.05, redRelativeThreshold=0.1);
Title h=12pt justify=center "CAP-кривая на выборке для количественного тестирования для модели уровня вероятности выздоровления";
%m_roc_curve(rawDataSet=rawValDataSet, inputVar=&cureModelVar._act, actualVar=&cureModelVar._mod, periodVar=&period, periodLabelVar=&period_label);


%mend m_lgd_SME_PS;

%macro m_elastic_rr(rawDataSet =, paymentVar=, costsVar=, eadVar=,  bucketVar=, labelName=,
					yellowThreshold=0.5, redThreshold=0.6);


proc sql noprint;
create table bucket_count as 
select distinct 
	&bucketVar
from &rawDataSet;
select 
	count(*)
	into:count_bucket
from 
	bucket_count;
quit;

proc sql noprint;
create table count_table as
select 
	&bucketVar,
	sum(&paymentVar) as payment,
	sum(&costsVar) as costs,
	sum(&eadVar) as EAD
from 
	&rawDataSet
GROUP BY 
	&bucketVar;
quit;

data count_table;
	set count_table;
		RR_old = (payment - costs)/EAD;
		RR_new = (payment - costs * 1.1)/EAD;
run;

data count_table;
	set count_table;
	elastick = 100* (RR_new - RR_old) / RR_new;
run;

data count_table;
		set count_table;
		select;
			when (elastick < &redThreshold.)	   	light = "красный";
			when (elastick < &yellowThreshold.) 	light = "желтый";
			otherwise 					   			light = "зеленый";
		end;
		format 
			elastick bestd6.5
			;
	run;

proc format;
	value $BACKCOLOR_FMT 	"зеленый"="vlig"
			  				"желтый"="yellow"
							"красный"="salmon";
run;

TITLE2 h=12pt justify=left "Выборка &labelName. ";
	proc print data=count_table noobs label;
		var &bucketVar. elastick ;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label	&bucketVar. = "Номер бакета выздоровления"
				elastick = "Эластичность"
				light = "Светофор";
	run;
%mend m_elastic_rr;

%macro m_elastic_lgd(rawDataSet =, paymentVar=, costsVar=, eadVar=,  cureBucketVar=, rrBucketVar=, labelName=,
					yellowThreshold=0.5, redThreshold=0.6);




proc sql;
create table count_table as
select
	&cureBucketVar,
	&rrBucketVar,
	sum(&paymentVar) as payment,
	sum(&costsVar) as costs,
	sum(&eadVar) as EAD
from 
	&rawDataSet
group by 
	&cureBucketVar,
	&rrBucketVar
order by
	&cureBucketVar,
	&rrBucketVar;

quit;

data count_table;
	set count_table;
		RR_old = (payment - costs)/EAD;
		RR_new = (payment - costs * 1.1)/EAD;
run;

data count_table;
	set count_table;
		LGD_old = 1 - RR_old;
		LGD_new = 1 - RR_new;
run;

data count_table;
	set count_table;
	elastick = 100* (LGD_new - LGD_old) / LGD_new;
run;

proc format;
	value $BACKCOLOR_FMT 	"зеленый"="vlig"
			  				"желтый"="yellow"
							"красный"="salmon";
run;

data count_table;
		set count_table;
		select;
			when (elastick > &redThreshold.)	   	light = "красный";
			when (elastick > &yellowThreshold.) 	light = "желтый";
			otherwise 					   			light = "зеленый";
		end;
		format 
			elastick bestd5.4
			;
	run;




TITLE2 h=12pt justify=left "Выборка &labelName. ";

	proc print data=count_table noobs label;
		var &cureBucketVar &rrBucketVar elastick ;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label	&cureBucketVar = "Номер бакета выздоровления"
				&rrBucketVar = "Номер бакета возмещения"
				elastick = "Эластичность"
				light = "Светофор";
	run;

%mend m_elastic_lgd;



%macro m_lgd_CL (rawDataSet=, recoveryModelVar=, defaultModelVar=, 
						period=, period_label=);

proc sql;
create table rawDevDataSet as 
select *
from &rawDataSet
where period = 1;
create table rawValDataSet as
select *
from &rawDataSet
where period = 2;
quit;

Title h=12pt justify=center "Коэффициент Джини модифицированный (на уровне модели уровня возмещения)";
%m_print_modif_gini(rawValDataSet=rawValDataSet, rawDevDataSet=rawDevDataSet, outputVar=&recoveryModelVar._mod, actualVar=&recoveryModelVar._act, actualVarEAD=0, inputVarList=0,
						  factorLabelSet=0, yellowFactorThreshold=0.1, redFactorThreshold=0.05, yellowModelThreshold=0.3, redModelThreshold=0.15,
						  yellowRelativeThreshold=0.05, redRelativeThreshold=0.1);
Title h=12pt justify=center "CAP-кривая на выборке для количественного тестирования для модели уровня возмещения";
%m_roc_curve(rawDataSet=rawValDataSet, inputVar=&recoveryModelVar._mod, actualVar=&recoveryModelVar._act, periodVar=&period, periodLabelVar=&period_label);

Title h=12pt justify=center "Коэффициент Джини модифицированный (на уровне модели уровня потерь в случае дефолта)";
%m_print_modif_gini(rawValDataSet=rawValDataSet, rawDevDataSet=rawDevDataSet, outputVar=&defaultModelVar._mod, actualVar=&defaultModelVar._act, actualVarEAD=0, inputVarList=0,
						  factorLabelSet=0, yellowFactorThreshold=0.1, redFactorThreshold=0.05, yellowModelThreshold=0.3, redModelThreshold=0.15,
						  yellowRelativeThreshold=0.05, redRelativeThreshold=0.1);

Title h=12pt justify=center "CAP-кривая на выборке для количественного тестирования для модели уровня потерь в случае дефолта";
%m_roc_curve(rawDataSet=rawValDataSet, inputVar=&defaultModelVar._mod, actualVar=&defaultModelVar._act, periodVar=&period, periodLabelVar=&period_label);

Title1 h=12pt justify=center "Оценка эластичности модели уровня возмещения по издержкам";
%m_elastic_rr(rawDataSet =rawValDataSet, paymentVar=payment, costsVar=costs, eadVar=EAD,  bucketVar=rr_bucket, labelName= Валидация,
					yellowThreshold=0.5, redThreshold=0.6);

%m_elastic_rr(rawDataSet =rawDevDataSet, paymentVar=payment, costsVar=costs, eadVar=EAD,  bucketVar=rr_bucket, labelName= Разработка,
					yellowThreshold=0.5, redThreshold=0.6);
Title1;
Title1 h=12pt justify=center "Оценка эластичности модели LGD по издержкам";
%m_elastic_lgd(rawDataSet = rawValDataSet, paymentVar=payment, costsVar=costs, eadVar=EAD,  cureBucketVar=cure_bucket, rrBucketVar=rr_bucket, labelName=Валидцаия,
					yellowThreshold=0.5, redThreshold=0.6);

%m_elastic_lgd(rawDataSet = rawDevDataSet, paymentVar=payment, costsVar=costs, eadVar=EAD,  cureBucketVar=cure_bucket, rrBucketVar=rr_bucket, labelName=Разработка,
					yellowThreshold=0.5, redThreshold=0.6);
Title1;

%mend m_lgd_CL;



%macro m_lgd_AU (rawDataSet=, recoveryModelVar=, defaultModelVar=, 
						period=, period_label=);

proc sql;
create table rawDevDataSet as 
select *
from &rawDataSet
where period = 1;
create table rawValDataSet as
select *
from &rawDataSet
where period = 2;
quit;

Title h=12pt justify=center "Коэффициент Джини модифицированный (на уровне модели уровня возмещения)";
%m_print_modif_gini(rawValDataSet=rawValDataSet, rawDevDataSet=rawDevDataSet, outputVar=&recoveryModelVar._mod, actualVar=&recoveryModelVar._act, actualVarEAD=0, inputVarList=0,
						  factorLabelSet=0, yellowFactorThreshold=0.1, redFactorThreshold=0.05, yellowModelThreshold=0.3, redModelThreshold=0.15,
						  yellowRelativeThreshold=0.05, redRelativeThreshold=0.1);
Title h=12pt justify=center "CAP-кривая на выборке для количественного тестирования для модели уровня возмещения";
%m_roc_curve(rawDataSet=rawValDataSet, inputVar=&recoveryModelVar._mod, actualVar=&recoveryModelVar._act, periodVar=&period, periodLabelVar=&period_label);

Title h=12pt justify=center "Коэффициент Джини модифицированный (на уровне модели уровня потерь в случае дефолта)";
%m_print_modif_gini(rawValDataSet=rawValDataSet, rawDevDataSet=rawDevDataSet, outputVar=&defaultModelVar._mod, actualVar=&defaultModelVar._act, actualVarEAD=0, inputVarList=0,
						  factorLabelSet=0, yellowFactorThreshold=0.1, redFactorThreshold=0.05, yellowModelThreshold=0.3, redModelThreshold=0.15,
						  yellowRelativeThreshold=0.05, redRelativeThreshold=0.1);
Title h=12pt justify=center "CAP-кривая на выборке для количественного тестирования для модели уровня потерь в случае дефолта";
%m_roc_curve(rawDataSet=rawValDataSet, inputVar=&defaultModelVar._mod, actualVar=&defaultModelVar._act, periodVar=&period, periodLabelVar=&period_label);

Title1 h=12pt justify=center "Оценка эластичности модели уровня возмещения по издержкам";
%m_elastic_rr(rawDataSet =rawValDataSet, paymentVar=payment, costsVar=costs, eadVar=EAD,  bucketVar=rr_bucket, labelName= Валидация,
					yellowThreshold=0.5, redThreshold=0.6);

%m_elastic_rr(rawDataSet =rawDevDataSet, paymentVar=payment, costsVar=costs, eadVar=EAD,  bucketVar=rr_bucket, labelName= Разработка,
					yellowThreshold=0.5, redThreshold=0.6);
Title1;
Title1 h=12pt justify=center "Оценка эластичности модели LGD по издержкам";
%m_elastic_lgd(rawDataSet = rawValDataSet, paymentVar=payment, costsVar=costs, eadVar=EAD,  cureBucketVar=cure_bucket, rrBucketVar=rr_bucket, labelName=Валидцаия,
					yellowThreshold=0.5, redThreshold=0.6);

%m_elastic_lgd(rawDataSet = rawDevDataSet, paymentVar=payment, costsVar=costs, eadVar=EAD,  cureBucketVar=cure_bucket, rrBucketVar=rr_bucket, labelName=Разработка,
					yellowThreshold=0.5, redThreshold=0.6);
Title1;

%mend m_lgd_AU;

%macro LGD_TEST_MACROS_MG (rawDataSet=, dataVar=, modelVar=, actualVar=, zoneName=);
Title "&zoneName.";


proc sgplot data=&rawDataset;
	label
		INDEX_FACT =  "Фактические значения"
		INDEX_MODEL = "Модельные значения"
		;
	refline 85 to 130 by 5 / axis=y;
	series x=&dataVar y=&modelVar ;
	series x1=&dataVar y=&actualVar;
	xaxis label="    ";
	yaxis label="    ";
run;

data INPUT_SET;
	set &rawDataSet;
	relative = ABS((&modelVar  - &actualVar) / &actualVar);
run;

proc sql;
create table relative_dataset as
select distinct
	region_nm,
	AVG(relative) as avg_relative
from 
	INPUT_SET
where 
	relative ^= 0;
quit;


data relative_dataset;
		set relative_dataset;
		select;
			when (avg_relative > 0.3)	   	light = "красный";
			when (avg_relative > 0.2) 		light = "желтый";
			otherwise 				light = "зеленый";
		end;

	run;

proc sql noprint;
select 
	region_nm
	into: var1
from 
	relative_dataset;

select 
	avg_relative
	into: var2
from 
	relative_dataset;

select 
	light
	into: var3
from 
	relative_dataset;

insert into relative_results_table 
values("&var1.", &var2, "&var3.");
quit;




data INPUT_SET_2;
	set &rawDataset;
run;

data INPUT_SET_3;
	set INPUT_SET_2;
		RSS = (&modelVar - &actualVar)**2;
run;

proc sql noprint;
create table INPUT_SET_4 as 
select distinct
	REGION_NM,
	sum(RSS) as RSS,
	AVG(&actualVar) as AVG
from INPUT_SET_3;
quit;

proc sql noprint;
select count(&dataVar)
	into: count_var
from INPUT_SET_3
where RSS ^= 0;
quit;

data INPUT_SET_5;
	set INPUT_SET_4;
		RMSE = sqrt(RSS / (&count_var - 1)) / AVG;
run;

data INPUT_SET_6;
		set INPUT_SET_5;
		select;
			when (RMSE > 0.2)	   	light = "красный";
			when (RMSE > 0.1) 		light = "желтый";
			otherwise 				light = "зеленый";
		end;
		format 
			RMSE bestd5.4
			;
	run;

proc sql noprint;
select 
	region_nm
	into: var1
from 
	INPUT_SET_6;

select 
	RMSE
	into: var2
from 
	INPUT_SET_6;

select 
	light
	into: var3
from 
	INPUT_SET_6;
insert into RMSE_results_table
values("&var1.", &var2,"&var3.");
quit;
	

%mend LGD_TEST_MACROS_MG;

%macro m_PSI_test (rawDataSet=, sortVar=, scaleVar=, periodVar=, modelName = );

data INPUT_VAR;
	set &rawDataSet;
run;

proc sql;
create table INPUT_VAR_1 as (
select 
	&sortVar,
	&periodVar,
	sum(&scaleVar) as scaleVar
from 
	INPUT_VAR
GROUP BY 
	&sortVar,
	&periodVar
);

create table INPUT_VAR_2  as (
select distinct
	a.&sortVar,
	(a.scaleVAR - b.scaleVar) * log(a.scaleVAR/b.scaleVAR) as PSI
from 
	INPUT_VAR_1 as a,
	INPUT_VAR_1 as b
where 
	a.&sortVar = b.&sortVar  and a.&periodVar = 1 and b.&periodVar = 2
);
quit;

data INPUT_VAR_2;
		set INPUT_VAR_2;
		select;
			when (PSI > 0.2)	   	light = "красный";
			when (PSI > 0.1) 		light = "желтый";
			otherwise 				light = "зеленый";
		end;
		format 
			psi bestd8.7
			;
	run;

proc format;
	value $BACKCOLOR_FMT 	"зеленый"="vlig"
			  				"желтый"="yellow"
							"красный"="salmon";
run;

Title h=12pt justify=left "&modelName.. Значения показателя PSI ";

	proc print data=INPUT_VAR_2 noobs label;
		var  &sortVar PSI ;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label	
			light = "Светофор"
			groups = "Сегмент";
	run;


%mend m_PSI_test;

%macro m_lossShortFall_test (rawDataSet=, sortVar=, scaleVarMod=, scaleVarAct=, periodVar=);

proc sql;
create table INPUT_VAR as 
select 
	* 
from 
	&rawDataSet
where 
	&periodVar = 2;
quit;

proc sql;
create table INPUT_VAR_1 as (
select 
	&sortVar,
	sum(&scaleVarMod) as scaleVarMod,
	sum(&scaleVarAct) as scaleVarAct
from 
	INPUT_VAR
GROUP BY 
	&sortVar
UNION
SELECT
	"All portfolio", 
	sum(&scaleVarMod),
	sum(&scaleVarAct)
FROM 
	INPUT_VAR
);

create table INPUT_VAR_2  as (
select distinct
	&sortVar,
	(scaleVarAct - scaleVarMod) / scaleVarAct as lossShortFall
from 
	INPUT_VAR_1
);
quit;

data INPUT_VAR_2;
		set INPUT_VAR_2;
		select;
			when (lossShortFall > 0.2)	   	light = "красный";
			when (lossShortFall > 0.1) 		light = "желтый";
			otherwise 						light = "зеленый";
		end;
		format 
			lossShortFall percent7.2
			;
	run;

proc format;
	value $BACKCOLOR_FMT 	"зеленый"="vlig"
			  				"желтый"="yellow"
							"красный"="salmon";
run;

Title h=12pt justify=left "Значения показателя LossShortFall ";

	proc print data=INPUT_VAR_2 noobs label;
		var  &sortVar lossShortFall ;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label	
			light = "Светофор"
			age_in_default = "Время в дефолте";
	run;

%mend m_lossShortFall_test;


%macro m_LGD_TEST(rawDataSet=, modelId=);

%if "&modelId" = "IFRS9_0201" 
	%then %m_lgd_CL (rawDataSet=&rawDataSet, recoveryModelVar=RR, defaultModelVar=LGD, 
						period=period, period_label=periodLabel);;
%if "&modelId." = "IFRS9_0202"
	%then %m_lgd_AU (rawDataSet=&rawDataSet, recoveryModelVar=RR, defaultModelVar=LGD, 
						period=period, period_label=periodLabel);;
%if "&modelId." = "IFRS9_0203" 
	%then 
		%do;
		proc sql;
		create table DATASET_rus as
		select 
			*
		from 
			TD_SBX.KVA_LGD_MG_DIRECTORY
		WHERE 
			REGION_NM = "РОССИЯ"
		order by REPORT_DT;

		create table DATASET_mos as
		select 
			*
		from 
			TD_SBX.KVA_LGD_MG_DIRECTORY
		WHERE 
			REGION_NM = "МОСКВА"
		order by REPORT_DT;

		create table DATASET_mos_reg as
		select 
			*
		from 
			TD_SBX.KVA_LGD_MG_DIRECTORY
		WHERE 
			REGION_NM = "МОСКОВСКАЯ ОБЛАСТЬ"
		order by REPORT_DT;

		create table DATASET_pet as
		select 
			*
		from 
			TD_SBX.KVA_LGD_MG_DIRECTORY
		WHERE 
			REGION_NM = "САНКТ-ПЕТЕРБУРГ"
		order by REPORT_DT;
		create table RMSE_results_table (
		region_nm CHAR(50),
		RMSE num,
		light CHAR(20)
		);
		create table relative_results_table (
		region_nm CHAR(50),
		avg_relative num,
		light CHAR(20)
		);
		quit;
		
		%LGD_TEST_MACROS_MG(rawDataSet=DATASET_rus, dataVar=REPORT_DT, modelVar=INDEX_MODEL,
						actualVar=INDEX_FACT, zoneName=Российская Федерация);
		%LGD_TEST_MACROS_MG(rawDataSet=DATASET_mos, dataVar=REPORT_DT, modelVar=INDEX_MODEL,
						actualVar=INDEX_FACT, zoneName=МОСКВА);
		%LGD_TEST_MACROS_MG(rawDataSet=DATASET_mos_reg, dataVar=REPORT_DT, modelVar=INDEX_MODEL,
						actualVar=INDEX_FACT, zoneName=Московская Область);
		%LGD_TEST_MACROS_MG(rawDataSet=DATASET_pet, dataVar=REPORT_DT, modelVar=INDEX_MODEL,
						actualVar=INDEX_FACT, zoneName=Санкт-Петербург);


		proc format;
			value $BACKCOLOR_FMT 	"зеленый"="vlig"
					  				"желтый"="yellow"
									"красный"="salmon";
		run;

		data relative_results_table;
			set relative_results_table;
			format 
				avg_relative percent7.2
				; 
		run;

		Title h=12pt justify=left "Значение среднего относительного отклонения ";

			proc print data=relative_results_table noobs label;
				var  region_nm avg_relative ;
				var light / style(data)=[background=$BACKCOLOR_FMT.];
				label	
					region_nm = "Регион"
					avg_relative = "Среднее относительное отклонение"
					light = "Светофор";
			run;

		Title h=12pt justify=left "Значения показателя RMSE ";
		proc print data=RMSE_results_table noobs label;
			var  region_nm RMSE ;
			var light / style(data)=[background=$BACKCOLOR_FMT.];
			label	
					region_nm = "Регион"
					light = "Светофор"
					;
		run;

		proc sql;
		create table sum_lgd_table as
		select 
			SUM(LGD_act) as LGD_act,
			SUM(LGD_mod) as LGD_mod
		from 
			&rawDataSet; 
		create table LossShortFall_table  as (
		select distinct
			abs((LGD_act - LGD_mod) / LGD_act) as lossShortFall
		from 
			sum_lgd_table
		);
		quit;



		data LossShortFall_table_2;
				set LossShortFall_table;
				select;
					when (lossShortFall > 0.2)	   	light = "красный";
					when (lossShortFall > 0.1) 		light = "желтый";
					otherwise 						light = "зеленый";
				end;
				format 
					lossShortFall percent7.2
					;
			run;


		Title h=12pt justify=left "Значения показателя LossShortFall ";

			proc print data=LossShortFall_table_2 noobs label;
				var	lossShortFall ;
				var light / style(data)=[background=$BACKCOLOR_FMT.];
				label	
						light = "Светофор";
			run;
		%end;;


%if "&modelId." = "IFRS9_0204"
	%then 
		%do;
		proc sql;
			create table counting_0_table as 
			select 
				*,
				SUM(EAD) as sum_ead
			from 
				&rawDataSet
			GROUP BY 
				groups,
				age_in_default;

			create table counting_1_table as 
			select 
				*, 
				ead/sum_ead as weight
			from 
				counting_0_table;

			create table counting_2_table as
			select 
				*,
				lgd_act * weight as lgd_act_weight, 
				lgd_mod * weight as lgd_mod_weight
			from 
				counting_1_table;

			create table results_table as 
			select 
				groups,
				age_in_default,
				count(migr_root_agreement_rk) as obs,
				sum(lgd_act_weight) as lgd_act,
				sum(lgd_mod_weight) as lgd_mod,
				period,
				periodLabel
			from 
				counting_2_table
			group by
				groups,
				age_in_default,
				period,
				periodLabel;

			quit;


		%m_PSI_test (rawDataSet=results_table, sortVar=groups, scaleVar=obs, periodVar=period,
					modelName = Оценка стабильности на уровне сегментации портфеля);
		%m_PSI_test (rawDataSet=results_table, sortVar=groups, scaleVar=LGD_act, periodVar=period,
					modelName = Оценка стабильности LGD на уровне модели);
		%m_lossShortFall_test (rawDataSet=results_table, sortVar=age_in_default, scaleVarMod=LGD_mod, 
						scaleVarAct=LGD_act, periodVar=period);

		%end;;

%if "&modelId." = "IFRS9_0205"
	%then %m_lgd_SME_PS (rawDataSet=&rawDataSet, recoveryModelVar=RR, defaultModelVar=LGD,cureModelVar=cure_flg, 
						period=period, period_label=period_label);;

%if "&modelId." = "IFRS9_0206"
	%then 
		%do;
		proc sql;
			create table counting_0_table as 
			select 
				*,
				SUM(EAD) as sum_ead
			from 
				&rawDataSet
			GROUP BY 
				groups,
				age_in_default;

			create table counting_1_table as 
			select 
				*, 
				ead/sum_ead as weight
			from 
				counting_0_table;

			create table counting_2_table as
			select 
				*,
				lgd_act * weight as lgd_act_weight, 
				lgd_mod * weight as lgd_mod_weight
			from 
				counting_1_table;

			create table results_table as 
			select 
				groups,
				age_in_default,
				count(migr_root_agreement_rk) as obs,
				sum(lgd_act_weight) as lgd_act,
				sum(lgd_mod_weight) as lgd_mod,
				period,
				periodLabel
			from 
				counting_2_table
			group by
				groups,
				age_in_default,
				period,
				periodLabel;

			quit;
		%m_PSI_test (rawDataSet=results_table, sortVar=groups, scaleVar=obs, periodVar=period, 
					modelName = Оценка стабильности на уровне сегментации портфеля.);
		%m_PSI_test (rawDataSet=results_table, sortVar=groups, scaleVar=LGD_act, periodVar=period,
					modelName = Оценка стабильности LGD на уровне модели);
		%m_lossShortFall_test (rawDataSet=results_table, sortVar=age_in_default, scaleVarMod=LGD_mod, 
						scaleVarAct=LGD_act, periodVar=period);

		%end;;

%mend m_LGD_TEST;









%macro m_ead_tests_au (rawDataset=,prepaymentFlgVar=, prepaymentVar=, portfolioName=);

data INPUT_SET_0;
	set &rawDataset;
run;

proc sql;
create table INPUT_SET as 
select 
	AVG(&prepaymentFlgVar._act) as prepayment_flg_act,
	AVG(&prepaymentFlgVar._mod) as prepayment_flg_mod,
	SUM(&prepaymentVar._act) as prepayment_act,
	SUM(&prepaymentVar._mod) as prepayment_mod
from INPUT_SET_0;
create table INPUT_SET_prepayment_flg as 
select 
	AVG(&prepaymentFlgVar._act) as prepayment_flg_act,
	AVG(&prepaymentFlgVar._mod) as prepayment_flg_mod
from INPUT_SET;
create table INPUT_SET_prepayment as 
select 
	SUM(&prepaymentVar._act) as prepayment_act,
	SUM(&prepaymentVar._mod) as prepayment_mod
from INPUT_SET;
quit;

data INPUT_SET_prepayment_flg;
	set INPUT_SET_prepayment_flg;
	relative = ABS((prepayment_flg_act - prepayment_flg_mod) / prepayment_flg_act);
	format 
		relative percent7.1
		prepayment_flg_act percent7.1
		prepayment_flg_mod percent7.1;
run;

proc format;
	picture million(round) 0-1e12 = '000009' ( mult=0.000001);
run;

data INPUT_SET_prepayment;
	set INPUT_SET_prepayment;
	relative = ABS((prepayment_act - prepayment_mod) / prepayment_act);
	format 
		relative percent7.1
		prepayment_act million.
		prepayment_mod million.;
run;

proc format;
	value $BACKCOLOR_FMT 	"зеленый"="vlig"
			  				"желтый"="yellow"
							"красный"="salmon";
run;

data INPUT_SET_prepayment_flg;
		set INPUT_SET_prepayment_flg;
		select;
			when (relative > 0.5)	   	light = "красный";
			when (relative > 0.25) 		light = "желтый";
			otherwise 					light = "зеленый";
		end;
	run;




Title h=12pt justify=left "Вероятность досрочного погашения";

	proc print data=INPUT_SET_prepayment_flg noobs label ;
		var  prepayment_flg_act prepayment_flg_mod relative ;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label	
				prepayment_flg_act = "Фактическое значение"
				prepayment_flg_mod = "Модельное значение"
				relative = "Отклонение"
				light = "Светофор";
	run;



data INPUT_SET_prepayment;
		set INPUT_SET_prepayment;
		select;
			when (relative > 0.5)	   	light = "красный";
			when (relative > 0.25) 		light = "желтый";
			otherwise 					light = "зеленый";
		end;
	run;



Title h=12pt justify=left "Уровень досрочного погашения ";

	proc print data=INPUT_SET_prepayment noobs label;
		var  prepayment_act prepayment_mod relative ;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label	
			prepayment_act = "Фактическое значение(млн.руб)"
			prepayment_mod = "Модельное значение(млн.руб)"
			relative = "Отклонение"
			light = "Светофор";
	run;

data INPUT_SET_2 ;
	set &rawDataSet (obs=1);
	over_value_reserve = underrestimation * balance_second_stage * reservation_rate;
	format 
		over_value_reserve million.
		underrestimation percent7.1
		balance_second_stage million.
		reservation_rate percent7.1
	;
run;

Title h=12pt justify=left "Влияние на ECL"; 

proc sql;
create table final_data_table as 
select 
	balance_second_stage,
	underrestimation,
	reservation_rate,
	over_value_reserve
from INPUT_SET_2;
quit;

	proc print data=final_data_table noobs label;
		var  balance_second_stage underrestimation reservation_rate over_value_reserve ;
		label	
			balance_second_stage = "Баланс вторая стадия(млн.руб)"
			underrestimation = "Отклонение досрочного погашения"
			reservation_rate = "Ставка резервирования"
			over_value_reserve = "Отклонение ECL(млн.руб)";
	run;
	
		
%mend m_ead_tests_au;

%macro m_EAD_tests_cc (rawDataSet=, portfolioName=, scenarioName = );


data INPUT_SET_0;
	set &rawDataSet.;
	moth_deff = intck('month',REPORT_DT,DEFAULT_START_DT);
run;

proc format;
	picture million(round) 0-1e12 = '000009' ( mult=0.000001);
	picture billion(round) 0-1e15 = '000009' ( mult=0.000000001);
	value $BACKCOLOR_FMT 	"зеленый"="vlig"
			  				"желтый"="yellow"
							"красный"="salmon";
run;

proc sql;
create table INPUT_SET as 
select 
	*,
	CASE WHEN moth_deff > 11 then 2
		ELSE 1 
		END as YEAR_IN_DEFAULT
from INPUT_SET_0;

create table EAD_stage_table as
select 
	"Стадия 1" as stage_nm,
	SUM(EAD_ACT) as EAD_act,
	SUM(EAD_mod) as EAD_mod,
	SUM(ECL) as ECL
from 
	INPUT_SET
WHERE stage = 1
union
select 
	"Стадия 2 (1  год)" as stage_nm,
	SUM(EAD_ACT) as EAD_act,
	SUM(EAD_mod) as EAD_mod,
	SUM(ECL) as ECL
from 
	INPUT_SET
WHERE stage = 2 and YEAR_IN_DEFAULT = 1
union
select 
	"Стадия 2 (со второго года жизни)" as stage_nm,
	SUM(EAD_ACT) as EAD_act,
	SUM(EAD_mod) as EAD_mod,
	SUM(ECL) as ECL
from 
	INPUT_SET
WHERE stage = 1 and YEAR_IN_DEFAULT > 1;

create table reservation_rate_table as 
select 
	reservation_rate_stage_1 as reservation_rate
from 
	INPUT_SET (obs = 1)
union
select 
	reservation_rate_stage_2_first
from 
	INPUT_SET (obs = 1)
union
select 
	reservation_rate_stage_2_second
from 
	INPUT_SET (obs = 1);

create table all_EAD_table as 
select
	sum(EAD_act) as EAD_act,
	SUM(EAD_mod) as EAD_mod
from
	INPUT_SET;
quit;

data results_table;
	set EAD_stage_table;
	set reservation_rate_table;
	relative_EAD = abs(1 - EAD_mod / EAD_act);
	underRestimation_ECL =  EAD_act * relative_EAD * reservation_rate;
	format 
		EAD_act million.
		EAD_mod million.
		relative_EAD percent7.1
		reservation_rate percent7.1
		underRestimation_ECL million.
		ECL million.;
run;

proc sql;
create table all_ECL_table as 
select 
	SUM(underRestimation_ECL) as underRestimation_ECL,
	SUM(ECL) as ECL
from
	results_table;
quit;

data all_ECL_relative_table;
	set all_ECL_table;
	ratio_ECL = underRestimation_ECL /  ECL;
	format
		underRestimation_ECL million.
		ECL million.
		ratio_ECL percent7.1;
run; 

data all_EAD_relative_table;
	set all_EAD_table;
	relative_EAD = abs(1 - EAD_mod /  EAD_act);
	format 
		relative_EAD percent7.1
		EAD_mod million.
		EAD_act million.;
run; 

data all_EAD_relative_table;
	set all_EAD_relative_table;
		select;
			when (relative_EAD > 0.5)	light = "красный";
			when (relative_EAD > 0.25) 	light = "желтый";
			otherwise 					light = "зеленый";
		end;
run;

data all_ECL_relative_table;
	set all_ECL_relative_table;
		select;
			when (ratio_ECL > 0.5)	light = "красный";
			when (ratio_ECL > 0.25) 	light = "желтый";
			otherwise 					light = "зеленый";
		end;
run;

Title1 	h=12pt justify=center "&scenarioName.";
Title2	h=12pt justify=left "Влияние на ECL";
proc print data=results_table noobs label;
	var stage_nm EAD_act EAD_mod relative_EAD reservation_rate underRestimation_ECL ecl;
	label
		stage_nm = "Название стадии"
		EAD_act = "EAD фактическое значение(млн.руб)"
		EAD_mod = "EAD модельное значение(млн.руб)"
		relative_EAD = "Отклонение модельных EAD"
		reservation_rate = "Ставка резервирования"
		underRestimation_ECL = "Отклонение ECL(млн.руб)"
		ECL = "ECL(млн.руб)"
		;
run;

Title2 h=12pt justify=left "Относительное отклонение смоделированных значений EAD";
proc print data=all_EAD_relative_table noobs label;
	var EAD_act EAD_mod relative_EAD;
	var light / style(data)=[background=$BACKCOLOR_FMT.];
	label	
		EAD_act = "EAD фактическое значение(млн.руб)"
		EAD_mod = "EAD модельное значение(млн.руб)"
		relative_EAD = "Отклонение"
		light = "Светофор";
run;

Title2 h=12pt justify=left "Относительное отклонение резервов";
proc print data=all_ECL_relative_table noobs label;
	var underRestimation_ECL ecl ratio_ECL;
	var light / style(data)=[background=$BACKCOLOR_FMT.];
	label	
		underRestimation_ECL = "Отклонение ECL(млн.руб)"
		ratio_ECL = "Доля неучтенных ECL"
		light = "Светофор"
		ECL = "ECL(млн.руб)"
		;
run;
Title1;
%mend m_EAD_tests_cc;



%macro m_ead_tests_ss (rawDataSet=, portfolioName = );

proc format;
	picture million(round) 0-1e12 = '000009' ( mult=0.000001);
	picture billion(round) 0-1e15 = '000009' ( mult=0.000000001);
	value $BACKCOLOR_FMT 	"зеленый"="vlig"
			  				"желтый"="yellow"
							"красный"="salmon";
run;

proc sql;
create table prepayment_table_0 as
select 
	SUM(prepayment_act) as prepayment_act,
	SUM(prepayment_mod) as prepayment_mod
from	
	&rawDataSet;

create table prepayment_table as
select 
	prepayment_act,
	prepayment_mod,
	ABS((prepayment_act - prepayment_mod) / prepayment_act) as relative
from	
	prepayment_table_0;

create table main_overdue_table_0 as 
select 
	sum(main_issue_act) as main_issue_act,
	sum(overdue_issue_act) as overdue_issue_act,
	sum(main_issue_mod) as main_issue_mod,
	sum(overdue_issue_mod) as overdue_issue_mod
from &rawDataSet;

create table main_overdue_table_1 as 
select 
	main_issue_act + overdue_issue_act as main_overdue_act,
	main_issue_mod + overdue_issue_mod as main_overdue_mod
from main_overdue_table_0;

create table main_overdue_table as 
select 
	*,
	ABS(main_overdue_act - main_overdue_mod) / main_overdue_act as relative_main_overdue
from main_overdue_table_1;

create table balance_table as 
select 
	"Модель досрочного погашения(с учётом досрочного погашения для Стадии 2)" as model_name,
	sum(balance) as balance
from 
	&rawDataSet
where stage = 2
union 
select 
	"Модель оценки величины основного долга и просроченного основного долга",
	sum(balance) as balance
from 
	&rawDataSet;

create table reservation_rate_table as 
select 
	"Модель досрочного погашения(с учётом досрочного погашения для Стадии 2)" as model_name,
	reservation_rate_stage_2 as reservation_rate
from &rawDataSet
union
select 
	"Модель оценки величины основного долга и просроченного основного долга",
	reservation_rate
from &rawDataSet;


create table values_table as 
select 
	"Модель досрочного погашения(с учётом досрочного погашения для Стадии 2)" as model_name,
	prepayment_act as values_act,
	prepayment_mod as values_mod,
	relative as relative_values
from
	PREPAYMENT_TABLE
union
select 
	"Модель оценки величины основного долга и просроченного основного долга",
	* 
from
	MAIN_OVERDUE_TABLE;

create table results_table as 
select 
	a.*,
	b.balance,
	c.reservation_rate
from	
	values_table as a
	join balance_table as b on a.model_name = b.model_name
	join reservation_rate_table as c on a.model_name = c.model_name;
quit;


data results_table;
		set results_table;
		overRestimation_ECL = balance * relative_values * reservation_rate;
		ratio_ECL = overRestimation_ECL / balance;
		select;
			when (relative_values > 0.5)	light = "красный";
			when (relative_values > 0.25) 	light = "желтый";
			otherwise 						light = "зеленый";
		end;
		format 
			balance billion.
			values_act billion.
			values_mod billion.
			overRestimation_ECL million.
			ratio_ECL percent7.1
			relative_values percent7.1
			reservation_rate percent7.1;
			
	run;
Title h=12pt justify=left "Отклонение модельных значений от фактических";
	proc print data=results_table noobs label;
		var model_name values_act values_mod relative_values;
		var light / style(data)=[background=$BACKCOLOR_FMT.];
		label	
			model_name = "Название модели"
			values_act = "Фактическое значение(млн.руб)"
			values_mod = "Модельное значение(млн.руб)"
			relative_values = "Отклонение";
	run;

Title h=12pt justify=left "Влияние на ECL";
	proc print data=results_table noobs label;
		var model_name  balance relative_values reservation_rate overRestimation_ECL ratio_ECL;
		label	
			model_name = "Название модели"
			balance = "Баланс(млрд.руб)"
			ratio_ECL = "Доля неучтенных резервов"
			reservation_rate = "Ставка резервирования"
			overRestimation_ECL = "Отклонение ECL(млн.руб)"
			relative_values = "Отклонение";
	run;
%mend m_ead_tests_ss;




%macro m_EAD_TEST (rawDataSet=, modelId=);
Title;
				
				%if "&modelId" = "IFRS9_0301"
					%then 
						%do;
							%m_ead_tests_au (rawDataSet = &rawDataSet, prepaymentFlgVar = prepayment_flg, 
											prepaymentVar = prepayment, portfolioName = Кредиты наличными);
						%end;;
				%if "&modelId" = "IFRS9_0302"
					%then 
						%do;
							%m_ead_tests_au (rawDataSet = &rawDataSet, prepaymentFlgVar = prepayment_flg, 
											prepaymentVar = prepayment, portfolioName = Ипотека);
						%end;;

				%if "&modelId" = "IFRS9_0303"
					%then 
						%do;
							%m_ead_tests_au (rawDataSet = &rawDataSet, prepaymentFlgVar = prepayment_flg, 
											prepaymentVar = prepayment, portfolioName = Авто);
						%end;;
				%if "&modelId" = "IFRS9_0304"
					%then 
						%do;
							
							proc sql noprint;
	
							create table scenario_distinct_table as 
							select distinct
								SCENARIO
							from 
								&rawDataSet;

							select 
								count(*)
								into: scenario_count
							from	
								scenario_distinct_table;

							%let scenario_count = &scenario_count.;

							select distinct
								SCENARIO
								into :var1-:var&scenario_count.
							from 
								&rawDataSet;

							quit;

							%do scenario_number = 1 %to &scenario_count;
							proc sql;
							create table scenario_table as 
								select 
									* 
								from 
									&rawDataSet
								WHERE 
									SCENARIO = "&&var&scenario_number.";

							quit;
							%m_ead_tests_cc(rawDataSet=scenario_table, portfolioName = Кредитные карты,
											scenarioName = Сценарий: &&var&scenario_number.);
							%end;
						%end;;
					
				%if "&modelId" = "IFRS9_0305"
					%then 
						%do;
							
							proc sql noprint;
	
							create table scenario_distinct_table as 
							select distinct
								SCENARIO
							from 
								&rawDataSet;

							select 
								count(*)
								into: scenario_count
							from	
								scenario_distinct_table;

							%let scenario_count = &scenario_count.;

							select distinct
								SCENARIO
								into :var1-:var&scenario_count.
							from 
								&rawDataSet;

							quit;

							%do scenario_number = 1 %to &scenario_count;
							proc sql;
							create table scenario_table as 
								select 
									* 
								from 
									&rawDataSet
								WHERE 
									SCENARIO = "&&var&scenario_number.";

							quit;
							%m_ead_tests_cc(rawDataSet=scenario_table, portfolioName = Кредитные карты,
											scenarioName = Сценарий: &&var&scenario_number.);
							%end;
						%end;;

				%if "&modelId" = "IFRS9_0306"
					%then 
						%do;
							%m_ead_tests_ss(rawDataSet=&rawDataSet, portfolioName = КМБ Стандартный сегмент);
						%end;;


%mend m_EAD_TEST;





















