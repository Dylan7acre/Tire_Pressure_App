classdef TirePressureApp < matlab.apps.AppBase

    %% 1. PROPERTIES: DEFINING THE USER INTERFACE (UI) COMPONENTS
    % This section declares all the visual elements (buttons, labels, dropdowns) 
    % and background variables the app needs to function.
    properties (Access = public)
        UIFigure                        matlab.ui.Figure
        Image                           matlab.ui.control.Image
        
        % Top Controls (Buttons and status labels)
        LoadCSVButton                   matlab.ui.control.Button
        ManualEntryButton               matlab.ui.control.Button
        DaySummaryButton                matlab.ui.control.Button
        PressureSetterButton            matlab.ui.control.Button
        ThermalRegressionButton         matlab.ui.control.Button
        DataStatusLabel                 matlab.ui.control.Label
        TargetPressureEditField         matlab.ui.control.NumericEditField
        TargetPressureLabel             matlab.ui.control.Label
        
        % Dropdown Selection Bar (For filtering data by Car -> Date -> Time)
        SelectCarLabel                  matlab.ui.control.Label
        CarDropDown                     matlab.ui.control.DropDown
        SelectDateLabel                 matlab.ui.control.Label
        DateDropDown                    matlab.ui.control.DropDown
        SelectTimeLabel                 matlab.ui.control.Label
        TimeDropDown                    matlab.ui.control.DropDown
        AnalyzeSelectedButton           matlab.ui.control.Button
        
        % Header Information Labels (Displays metadata for the analyzed run)
        TrackLabel                      matlab.ui.control.Label
        CarLabel                        matlab.ui.control.Label
        SessionLabel                    matlab.ui.control.Label
        DateTimeLabel                   matlab.ui.control.Label
        EnvTempLabel                    matlab.ui.control.Label
        
        % Quadrants (The 4 boxes displaying individual tire data)
        FL_Panel, FL_ColdLabel, FL_HotLabel, FL_RawTempLabel, FL_TDiffLabel, FL_PSILapLabel, FL_AdjLabel
        FR_Panel, FR_ColdLabel, FR_HotLabel, FR_RawTempLabel, FR_TDiffLabel, FR_PSILapLabel, FR_AdjLabel
        RL_Panel, RL_ColdLabel, RL_HotLabel, RL_RawTempLabel, RL_TDiffLabel, RL_PSILapLabel, RL_AdjLabel
        RR_Panel, RR_ColdLabel, RR_HotLabel, RR_RawTempLabel, RR_TDiffLabel, RR_PSILapLabel, RR_AdjLabel
    end

    properties (Access = private)
        DataTable % Stores the entire master CSV data in memory while the app runs
        MasterFilePath % The hard drive file path to the persistent 'MasterData.csv'
    end

    %% 2. STARTUP & MASTER DATA MANAGEMENT
    methods (Access = private)
        
        % Runs automatically when the app is first opened
        function startupFcn(app)
            % Determine where the app is saved and look for MasterData.csv there
            appPath = fileparts(mfilename('fullpath'));
            app.MasterFilePath = fullfile(appPath, 'MasterData.csv');
            
            if isfile(app.MasterFilePath)
                try
                    % 1. Setup import options. We force 'Date' and 'Time' to load as 
                    % plain text ('char') to prevent MATLAB from throwing ambiguous date warnings.
                    opts = detectImportOptions(app.MasterFilePath, 'PreserveVariableNames', true);
                    opts = setvaropts(opts, 'Date', 'Type', 'char');
                    opts = setvaropts(opts, 'Time', 'Type', 'char');
                    
                    % 2. Load the data using the safe options
                    app.DataTable = readtable(app.MasterFilePath, opts);
                    
                    % Ensure Car numbers are treated as numbers, not text
                    if iscell(app.DataTable.Car) || isstring(app.DataTable.Car)
                        app.DataTable.Car = str2double(app.DataTable.Car);
                    end
                    app.DataTable.Date = string(app.DataTable.Date);
                    app.DataTable.Time = string(app.DataTable.Time);
                    
                    app.DataStatusLabel.Text = 'Status: Master Log Loaded';
                    app.DataStatusLabel.FontColor = [0.47 0.67 0.19]; % Green
                    
                    % Populate the "Car" dropdown with all unique car numbers found in the log
                    uniqueCars = unique(app.DataTable.Car(~isnan(app.DataTable.Car)));
                    app.CarDropDown.Items = cellstr(num2str(uniqueCars));
                    app.updateDateDropDown(); % Trigger cascade to update Dates
                catch ME
                    app.DataStatusLabel.Text = 'Status: Master Log Corrupted';
                    app.DataStatusLabel.FontColor = [0.85 0.33 0.10]; % Red
                    disp(ME.message);
                end
            else
                app.DataStatusLabel.Text = 'Status: No Master Log Found.';
            end
        end
        
        % The core engine for cleaning, sorting, and saving data. 
        % Called every time new data is loaded or manually entered.
        function processAndSaveMaster(app)
            df = app.DataTable;
            
            % 1. ROBUST DATE STANDARDIZATION
            % Convert all hyphens to slashes so all dates look identical (e.g. 10/10/2026)
            df.Date = strrep(string(df.Date), '-', '/'); 
            df.Time = string(df.Time);
            
            % Combine Date and Time into a formal MATLAB datetime array
            dtArray = datetime(df.Date + " " + df.Time, 'InputFormat', 'dd/MM/yyyy HH:mm:ss');
            
            % Save back as consistent string just in case
            df.Date = string(datetime(dtArray, 'Format', 'dd/MM/yyyy'));
            
            % 2. DEDUPLICATE & SORT
            % Remove any rows that have the exact same Date, Time, Car, and Hot/Cold state
            [~, uniqueIdx] = unique(table(df.Date, df.Time, df.Car, df.('Hot/Cold')), 'rows', 'stable');
            df = df(uniqueIdx, :);
            dtArray = dtArray(uniqueIdx);
            
            % Sort everything from oldest (top) to newest (bottom)
            [~, sortIdx] = sort(dtArray);
            df = df(sortIdx, :);
            
            % 3. SESSION TAGGING (FP Counter)
            % Ensure the 'Session' column exists
            if ~ismember('Session', df.Properties.VariableNames)
                df.Session = repmat({''}, height(df), 1);
            end
            if isnumeric(df.Session)
                df.Session = cellstr(num2str(df.Session));
            end
            
            uniqueCars = unique(df.Car(~isnan(df.Car)));
            uniqueDates = unique(df.Date);
            
            % Loop through every specific car on every specific day
            for c = 1:length(uniqueCars)
                for d = 1:length(uniqueDates)
                    % Isolate only the "Hot" runs for this car/day combo
                    maskHot = (df.Car == uniqueCars(c)) & strcmp(df.Date, uniqueDates(d)) & ...
                              strcmpi(strtrim(df.('Hot/Cold')), 'Hot');
                    hotIndices = find(maskHot);
                    fpCounter = 1; % Start Free Practice counter at 1 for the day
                    
                    for h = 1:length(hotIndices)
                        hotIdx = hotIndices(h);
                        
                        % Search backwards in time to find the Cold run just before this Hot run
                        coldIdx = [];
                        for i = (hotIdx - 1):-1:1
                            if df.Car(i) == uniqueCars(c) && strcmpi(strtrim(df.('Hot/Cold'){i}), 'Cold')
                                coldIdx = i; break;
                            end
                        end
                        
                        % Check if the logger accidentally put session names in the 'Tyre' column
                        existingStr = '';
                        if ismember('Tyre', df.Properties.VariableNames)
                            existingStr = strtrim(string(df.Tyre{hotIdx}));
                        end
                        
                        % If Tyre column is empty, check the actual Session column
                        if existingStr == "" || existingStr == "n/a" || existingStr == "NaN" || strcmpi(existingStr, 'Tyre')
                            existingStr = strtrim(string(df.Session{hotIdx}));
                        end
                        
                        % If it's Qualifying or a Race, keep the name. Otherwise, assign FP1, FP2, etc.
                        if contains(existingStr, 'Q', 'IgnoreCase', true) || contains(existingStr, 'R', 'IgnoreCase', true)
                            newSession = char(existingStr);
                        else
                            newSession = sprintf('FP%d', fpCounter);
                            fpCounter = fpCounter + 1;
                        end
                        
                        % Apply the session name to both the Hot run and its preceding Cold run
                        df.Session{hotIdx} = newSession;
                        if ~isempty(coldIdx), df.Session{coldIdx} = newSession; end
                    end
                end
            end
            
            % 4. CLEANUP & SAVE
            % Make sure 'Notes' column exists and handles empty/NaN values gracefully
            if ~ismember('Notes', df.Properties.VariableNames)
                df.Notes = repmat({''}, height(df), 1);
            end
            if ~iscell(df.Notes), df.Notes = cellstr(string(df.Notes)); end
            df.Notes(strcmp(df.Notes, 'NaN') | strcmp(df.Notes, 'n/a')) = {''};
            
            % Overwrite the active DataTable and save it to the hard drive
            app.DataTable = df;
            writetable(app.DataTable, app.MasterFilePath);
            
            % Update the UI to reflect the newly processed data
            app.CarDropDown.Items = cellstr(num2str(uniqueCars));
            app.updateDateDropDown();
            app.DataStatusLabel.Text = 'Status: Master Log Updated';
            app.DataStatusLabel.FontColor = [0.47 0.67 0.19];
        end
    end

    %% 3. UI DROPDOWN UPDATERS (Cascading Filters)
    methods (Access = private)
        % Updates the Date dropdown based on which Car is currently selected
        function updateDateDropDown(app)
            if isempty(app.DataTable); return; end
            df = app.DataTable;
            selCar = str2double(app.CarDropDown.Value);
            
            % Find dates where this car ran
            carMask = df.Car == selCar;
            validDates = unique(df.Date(carMask));
            
            if isempty(validDates)
                app.DateDropDown.Items = {'No Dates found'};
            else
                app.DateDropDown.Items = cellstr(validDates);
            end
            app.updateTimeDropDown(); % Trigger time update automatically
        end
        
        % Updates the Time dropdown based on which Car AND Date are selected
        function updateTimeDropDown(app)
            if isempty(app.DataTable); return; end
            df = app.DataTable;
            selCar = str2double(app.CarDropDown.Value);
            selDate = app.DateDropDown.Value;
            
            % Only show times for "Hot" runs to keep the dropdown clean
            mask = (df.Car == selCar) & strcmp(df.Date, selDate) & strcmpi(strtrim(df.('Hot/Cold')), 'Hot');
            validTimes = unique(df.Time(mask));
            
            if isempty(validTimes)
                app.TimeDropDown.Items = {'No Hot Times found'};
            else
                app.TimeDropDown.Items = cellstr(validTimes);
            end
        end
    end

    %% 4. MAIN UI CALLBACKS (Buttons and Actions)
    methods (Access = private)
        
        % LOAD CSV BUTTON
        function LoadCSVButtonPushed(app, event)
            % Open a file browser for the user to pick a new telemetry CSV
            [file, path] = uigetfile('*.csv', 'Select the Track Data CSV');
            if isequal(file, 0); return; end % Exit if user cancels
            
            fullFileName = fullfile(path, file);
            try
                % Apply safe import options (text for dates) just like startup
                opts = detectImportOptions(fullFileName, 'PreserveVariableNames', true);
                opts = setvaropts(opts, 'Date', 'Type', 'char');
                opts = setvaropts(opts, 'Time', 'Type', 'char');
                
                newData = readtable(fullFileName, opts);
                if iscell(newData.Car) || isstring(newData.Car)
                    newData.Car = str2double(newData.Car);
                end
                newData.Date = string(newData.Date);
                newData.Time = string(newData.Time);
                
                % Append the new file's data to the master table
                if isempty(app.DataTable)
                    app.DataTable = newData;
                else
                    app.DataTable = [app.DataTable; newData];
                end
                
                % Process, clean, sort, and save everything
                app.processAndSaveMaster();
            catch ME 
                uialert(app.UIFigure, ['File Error: ', ME.message], 'CSV Format Error');
            end
        end
        
        % MANUAL ENTRY BUTTON
        function ManualEntryButtonPushed(app, event)
            if isempty(app.DataTable)
                uialert(app.UIFigure, 'Please load at least one CSV first to establish the master table structure.', 'Missing Data');
                return;
            end
            
            % Create a pop-up window for data entry
            entryFig = uifigure('Name', 'Manual Data Entry', 'Position', [150 150 800 600]);
            
            % Create Metadata Inputs (Car, Date, Time, etc.)
            uilabel(entryFig, 'Position', [20 550 40 22], 'Text', 'Car:', 'FontWeight', 'bold');
            carEF = uieditfield(entryFig, 'numeric', 'Position', [60 550 60 22], 'Value', 14);
            
            uilabel(entryFig, 'Position', [140 550 40 22], 'Text', 'Date:', 'FontWeight', 'bold');
            dateEF = uieditfield(entryFig, 'text', 'Position', [180 550 90 22], 'Value', datestr(now, 'dd/mm/yyyy'));
            
            uilabel(entryFig, 'Position', [290 550 40 22], 'Text', 'Time:', 'FontWeight', 'bold');
            timeEF = uieditfield(entryFig, 'text', 'Position', [330 550 80 22], 'Value', datestr(now, 'HH:MM:SS'));
            
            uilabel(entryFig, 'Position', [430 550 45 22], 'Text', 'Track:', 'FontWeight', 'bold');
            trackEF = uieditfield(entryFig, 'text', 'Position', [475 550 100 22], 'Value', 'Snetterton');
            
            uilabel(entryFig, 'Position', [590 550 40 22], 'Text', 'State:', 'FontWeight', 'bold');
            stateDD = uidropdown(entryFig, 'Items', {'Hot', 'Cold'}, 'Position', [635 550 70 22]);
            
            uilabel(entryFig, 'Position', [20 520 70 22], 'Text', 'Amb Temp:');
            ambEF = uieditfield(entryFig, 'numeric', 'Position', [90 520 50 22]);
            
            uilabel(entryFig, 'Position', [160 520 80 22], 'Text', 'Track Temp:');
            trkEF = uieditfield(entryFig, 'numeric', 'Position', [240 520 50 22]);
            
            uilabel(entryFig, 'Position', [310 520 40 22], 'Text', 'Laps:');
            lapsEF = uieditfield(entryFig, 'numeric', 'Position', [350 520 50 22]);
            
            % Helper function to quickly create 4 identical entry boxes (quadrants)
            function [pEF, iEF, mEF, oEF] = createInputQuad(parent, titleStr, pos)
                pnl = uipanel(parent, 'Title', titleStr, 'Position', pos, 'FontSize', 12, 'FontWeight', 'bold');
                uilabel(pnl, 'Position', [10 70 100 22], 'Text', 'Pressure (PSI):');
                pEF = uieditfield(pnl, 'numeric', 'Position', [120 70 50 22]);
                uilabel(pnl, 'Position', [10 40 40 22], 'Text', 'In (C):');
                iEF = uieditfield(pnl, 'numeric', 'Position', [50 40 45 22]);
                uilabel(pnl, 'Position', [110 40 45 22], 'Text', 'Mid (C):');
                mEF = uieditfield(pnl, 'numeric', 'Position', [155 40 45 22]);
                uilabel(pnl, 'Position', [10 10 45 22], 'Text', 'Out (C):');
                oEF = uieditfield(pnl, 'numeric', 'Position', [55 10 45 22]);
            end
            
            % Build the 4 Quadrants in the pop-up
            [fl_p, fl_i, fl_m, fl_o] = createInputQuad(entryFig, 'FRONT LEFT (FL)', [40 310 230 130]);
            [fr_p, fr_i, fr_m, fr_o] = createInputQuad(entryFig, 'FRONT RIGHT (FR)', [530 310 230 130]);
            [rl_p, rl_i, rl_m, rl_o] = createInputQuad(entryFig, 'REAR LEFT (RL)', [40 140 230 130]);
            [rr_p, rr_i, rr_m, rr_o] = createInputQuad(entryFig, 'REAR RIGHT (RR)', [530 140 230 130]);
            
            % Save Button
            saveBtn = uibutton(entryFig, 'push', 'Text', 'Save Entry to Master Log', ...
                'Position', [300, 60, 200, 35], 'FontWeight', 'bold');
            
            % When Save is clicked, execute the nested function below
            saveBtn.ButtonPushedFcn = @(~, ~) saveManualData();
            
            % Nested function to process the manual inputs
            function saveManualData()
                try
                    % Create a blank row matching the exact schema of the Master Log
                    newRow = app.DataTable(1, :);
                    for col = 1:width(newRow)
                        if isnumeric(newRow{1, col}); newRow{1, col} = NaN;
                        elseif iscell(newRow{1, col}); newRow{1, col} = {''};
                        elseif isstring(newRow{1, col}); newRow{1, col} = ""; end
                    end
                    
                    % Map user inputs to the blank row
                    newRow.Car = carEF.Value;
                    newRow.Date = string(dateEF.Value);
                    newRow.Time = string(timeEF.Value);
                    newRow.Location = {trackEF.Value};
                    newRow.('Hot/Cold') = {stateDD.Value};
                    newRow.AmbT = ambEF.Value;
                    newRow.TrackT = trkEF.Value;
                    
                    % Convert Laps input to string for the Notes column
                    notesStr = string(lapsEF.Value); 
                    if notesStr == "0" || notesStr == "" || isnan(lapsEF.Value)
                        newRow.Notes = {''};
                    else
                        newRow.Notes = {char(notesStr)}; 
                    end
                    
                    % Populate pressures and temperatures.
                    % Note: Setting MaxP and EndP to the same value for manual entries
                    newRow.LFMaxP = fl_p.Value; newRow.LFEndP = fl_p.Value;
                    newRow.LFIn = fl_i.Value; newRow.LFMid = fl_m.Value; newRow.LFOut = fl_o.Value;
                    
                    newRow.RFMaxP = fr_p.Value; newRow.RFEndP = fr_p.Value;
                    newRow.RFIn = fr_i.Value; newRow.RFMid = fr_m.Value; newRow.RFOut = fr_o.Value;
                    
                    newRow.LRMaxP = rl_p.Value; newRow.LREndP = rl_p.Value;
                    newRow.LRIn = rl_i.Value; newRow.LRMid = rl_m.Value; newRow.LROut = rl_o.Value;
                    
                    newRow.RRMaxP = rr_p.Value; newRow.RREndP = rr_p.Value;
                    newRow.RRIn = rr_i.Value; newRow.RRMid = rr_m.Value; newRow.RROut = rr_o.Value;
                    
                    % Append and re-process the Master Log
                    app.DataTable = [app.DataTable; newRow];
                    app.processAndSaveMaster();
                    
                    uialert(app.UIFigure, 'Manual entry saved to Master Log!', 'Success');
                    close(entryFig); % Close pop-up
                catch ME
                    uialert(entryFig, ['Error saving entry: ' ME.message], 'Save Failed');
                end
            end
        end
        
        % PRESSURE SETTER BUTTON (Predictive Modeling)
        function PressureSetterButtonPushed(app, event)
            if isempty(app.DataTable); uialert(app.UIFigure, 'Load data first.', 'Error'); return; end
            setterFig = uifigure('Name', 'Ideal Starting Pressures (Thermal Model)', 'Position', [200 200 650 480]);
            
            df = app.DataTable;
            tracks = unique(regexprep(df.Location, '(?i)East Harling', 'Snetterton'));
            tracks = tracks(~cellfun('isempty', tracks) & ~strcmp(tracks, 'Manual Entry'));
            if isempty(tracks); tracks = {'Unknown'}; end
            
            uilabel(setterFig, 'Position', [20 430 50 22], 'Text', 'Track:', 'FontWeight', 'bold');
            trackDD = uidropdown(setterFig, 'Items', tracks, 'Position', [70 430 120 22]);
            
            uilabel(setterFig, 'Position', [220 430 70 22], 'Text', 'Amb Temp:');
            ambEF = uieditfield(setterFig, 'numeric', 'Position', [290 430 50 22], 'Value', 20);
            uilabel(setterFig, 'Position', [360 430 80 22], 'Text', 'Track Temp:');
            trkEF = uieditfield(setterFig, 'numeric', 'Position', [440 430 50 22], 'Value', 25);
            
            uilabel(setterFig, 'Position', [20 395 80 22], 'Text', 'Target Laps:', 'FontWeight', 'bold');
            lapsEF = uieditfield(setterFig, 'numeric', 'Position', [100 395 50 22], 'Value', 15);
            uilabel(setterFig, 'Position', [160 395 450 22], 'Text', '(Extrapolates short practice data into steady-state race temperatures)');
            
            uilabel(setterFig, 'Position', [20 360 600 22], 'Text', 'Current Tire Temps (Leave blank to auto-calculate from Amb/Track):', 'FontWeight', 'bold');
            uilabel(setterFig, 'Position', [20 330 30 22], 'Text', 'LF:'); lf_tEF = uieditfield(setterFig, 'numeric', 'Position', [50 330 50 22]);
            uilabel(setterFig, 'Position', [120 330 30 22], 'Text', 'RF:'); rf_tEF = uieditfield(setterFig, 'numeric', 'Position', [150 330 50 22]);
            uilabel(setterFig, 'Position', [220 330 30 22], 'Text', 'LR:'); lr_tEF = uieditfield(setterFig, 'numeric', 'Position', [250 330 50 22]);
            uilabel(setterFig, 'Position', [320 330 30 22], 'Text', 'RR:'); rr_tEF = uieditfield(setterFig, 'numeric', 'Position', [350 330 50 22]);
            
            pnl = uipanel(setterFig, 'Title', 'Calculated Ideal Starting Pressures', 'Position', [20 20 610 290], 'FontSize', 14, 'FontWeight', 'bold');
            resLabels = [uilabel(pnl, 'Position', [30 190 250 40], 'Text', 'LF: --- PSI', 'FontSize', 18, 'FontWeight', 'bold'), ...
                         uilabel(pnl, 'Position', [320 190 250 40], 'Text', 'RF: --- PSI', 'FontSize', 18, 'FontWeight', 'bold'), ...
                         uilabel(pnl, 'Position', [30 70 250 40], 'Text', 'LR: --- PSI', 'FontSize', 18, 'FontWeight', 'bold'), ...
                         uilabel(pnl, 'Position', [320 70 250 40], 'Text', 'RR: --- PSI', 'FontSize', 18, 'FontWeight', 'bold')];
                         
            uibutton(setterFig, 'push', 'Text', 'Calculate', 'Position', [420 329 150 24], 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) calc(trackDD, ambEF, trkEF, lapsEF, resLabels, df, app.TargetPressureEditField.Value));

            function calc(tDD, aEF, trkEF, lEF, labs, data, targ)
                t_amb = aEF.Value; t_trk = trkEF.Value; target_laps = lEF.Value;
                if isnan(t_amb) || isnan(t_trk); uialert(setterFig, 'Ambient and Track temperatures are required.', 'Input Error'); return; end
                if isnan(target_laps) || target_laps <= 0; target_laps = 15; end
                
                baseline_cold = (0.7 * t_amb) + (0.3 * t_trk);
                startT = [lf_tEF.Value, rf_tEF.Value, lr_tEF.Value, rr_tEF.Value];
                
                % Replace any value that is NaN OR exactly 0 with the baseline
                startT(isnan(startT) | startT == 0) = baseline_cold;
                
                maskH = strcmpi(regexprep(data.Location, '(?i)East Harling', 'Snetterton'), tDD.Value) & strcmpi(strtrim(data.('Hot/Cold')), 'Hot');
                hIdxs = find(maskH); 
                tires = {'LF', 'RF', 'LR', 'RR'};
                
                % Loop through all 4 tires completely independently
                for i = 1:4
                    qName = tires{i};
                    hist_Tamb = []; hist_Thot = []; coeff = []; hist_laps = [];
                    
                    for k = 1:length(hIdxs)
                        h = hIdxs(k); c = []; 
                        for j=(h-1):-1:1
                            if data.Car(j)==data.Car(h) && strcmpi(strtrim(data.('Hot/Cold'){j}), 'Cold'); c=j; break; end
                        end
                        
                        if ~isempty(c) && ~isnan(data.AmbT(c))
                            hist_cold = (0.7 * data.AmbT(c)) + (0.3 * data.TrackT(c));
                            avg_Thot = mean([data.([qName 'In'])(h), data.([qName 'Mid'])(h), data.([qName 'Out'])(h)], 'omitnan');
                            dP = data.([qName 'MaxP'])(h) - data.([qName 'EndP'])(c);
                            
                            if (avg_Thot - hist_cold) > 2 && dP > 0
                                coeff(end+1) = dP / (avg_Thot - hist_cold); %#ok<AGROW>
                                hist_Tamb(end+1) = data.AmbT(c); %#ok<AGROW>
                                hist_Thot(end+1) = avg_Thot; %#ok<AGROW>
                                
                                % Robust lap extraction
                                noteData = data.Notes(h);
                                if iscell(noteData); noteData = noteData{1}; end
                                if isnumeric(noteData) && ~isnan(noteData) && noteData > 0
                                    hist_laps(end+1) = noteData; %#ok<AGROW>
                                else
                                    nStr = string(noteData);
                                    if nStr ~= "" && nStr ~= "NaN" && nStr ~= "<missing>"
                                        val = str2double(regexp(nStr, '\d+', 'match', 'once'));
                                        if ~isnan(val) && val > 0; hist_laps(end+1) = val; end %#ok<AGROW>
                                    end
                                end
                            end
                        end
                    end
                    
                    if length(hist_Tamb) < 3
                        labs(i).Text = sprintf('%s: Insufficient Data', qName);
                        labs(i).FontColor = [0.85 0.33 0.10];
                        continue;
                    end
                    
                    avg_hist_laps = mean(hist_laps);
                    if isnan(avg_hist_laps) || avg_hist_laps <= 0; avg_hist_laps = 5; end 
                    
                    % Thermodynamic Extrapolation
                    heat_multiplier = (1 - exp(-0.3 * target_laps)) / (1 - exp(-0.3 * avg_hist_laps));
                    
                    mdl = fitlm(hist_Tamb, hist_Thot, 'RobustOpts', 'on');
                    pred_Thot = predict(mdl, t_amb);
                    
                    sat_deltaT = (pred_Thot - baseline_cold) * heat_multiplier;
                    sat_Thot = baseline_cold + sat_deltaT;
                    
                    C_exp = median(coeff);
                    ideal_press = targ - (C_exp * (sat_Thot - startT(i)));
                    
                    labs(i).Text = sprintf('%s: %.1f PSI', qName, ideal_press);
                    labs(i).FontColor = [0 0.45 0.74];
                end
            end
        end
        
        % Dropdown change triggers (simply refresh the options below them)
        function CarDropDownValueChanged(app, event); app.updateDateDropDown(); end
        function DateDropDownValueChanged(app, event); app.updateTimeDropDown(); end
        
        % ANALYZE SELECTED RUN BUTTON
        function AnalyzeSelectedButtonPushed(app, event)
            df = app.DataTable;
            targetCar = str2double(app.CarDropDown.Value);
            hotIdx = find(strcmp(df.Date, app.DateDropDown.Value) & strcmp(df.Time, app.TimeDropDown.Value) & df.Car == targetCar & strcmpi(strtrim(df.('Hot/Cold')), 'Hot'));
            if isempty(hotIdx); return; end; hotIdx = hotIdx(1);
            
            coldIdx = []; 
            for i=(hotIdx-1):-1:1
                if df.Car(i)==targetCar && strcmpi(strtrim(df.('Hot/Cold'){i}), 'Cold'); coldIdx=i; break; end
            end
            
            if isempty(coldIdx); uialert(app.UIFigure, 'No cold run found.', 'Error'); return; end
            
            % Robust lap extraction
            numLaps = 5; % Default fallback
            noteData = df.Notes(hotIdx);
            if iscell(noteData); noteData = noteData{1}; end
            if isnumeric(noteData) && ~isnan(noteData) && noteData > 0
                numLaps = noteData;
            else
                nStr = string(noteData);
                if nStr ~= "" && nStr ~= "NaN" && nStr ~= "<missing>"
                    val = str2double(regexp(nStr, '\d+', 'match', 'once'));
                    if ~isnan(val) && val > 0; numLaps = val; end
                end
            end
            
            app.TrackLabel.Text = ['Track: ' regexprep(df.Location{hotIdx}, '(?i)East Harling', 'Snetterton')];
            app.CarLabel.Text = sprintf('Car: %d', df.Car(hotIdx)); app.SessionLabel.Text = ['Session: ' df.Session{hotIdx}];
            app.DateTimeLabel.Text = ['Date: ' df.Date{hotIdx} ' | Time: ' df.Time{hotIdx}];
            app.EnvTempLabel.Text = sprintf('Amb: %.1f C | Trk: %.1f C', df.AmbT(hotIdx), df.TrackT(hotIdx));
            
            targ = app.TargetPressureEditField.Value;
            
            % Local helper function to apply the thermodynamic model to each quadrant
            function vals = calcQuadData(p_hot, p_cold, in, mid, out, laps, ambC, trkC, targetP)
                t_cold = (0.7 * ambC) + (0.3 * trkC);
                t_hot_avg = mean([in, mid, out], 'omitnan');
                
                dT_run = t_hot_avg - t_cold;
                dP_run = p_hot - p_cold;
                
                % Extrapolate the current run to a 15-lap steady state race stint
                heat_mult = (1 - exp(-0.3 * 15)) / (1 - exp(-0.3 * laps));
                
                if dT_run > 2 && dP_run > 0
                    c_exp = dP_run / dT_run;
                    dP_race = c_exp * (dT_run * heat_mult);
                    ideal_cold = targetP - dP_race;
                    idealStr = sprintf('Adj Target Cold: %.1f PSI', ideal_cold);
                else
                    idealStr = 'Adj Target Cold: N/A';
                end
                
                tDiff = abs(in - out);
                riseLap = dP_run / laps;
                
                vals = {sprintf('Prev Cold Press: %.1f PSI', p_cold), ...
                        sprintf('Meas Hot Press: %.1f PSI', p_hot), ...
                        sprintf('I/M/O: %.1f / %.1f / %.1f C', in, mid, out), ...
                        sprintf('|T-Diff| In->Out: %.1f C', tDiff), ...
                        sprintf('Press Rise/Lap: +%.2f PSI', riseLap), ...
                        idealStr};
            end
            
            ambC = df.AmbT(coldIdx); trkC = df.TrackT(coldIdx);
            
            % FL (Front Left) assignments using original FL_ property names
            lf_vals = calcQuadData(df.LFMaxP(hotIdx), df.LFEndP(coldIdx), df.LFIn(hotIdx), df.LFMid(hotIdx), df.LFOut(hotIdx), numLaps, ambC, trkC, targ);
            app.FL_ColdLabel.Text = lf_vals{1}; app.FL_HotLabel.Text = lf_vals{2}; app.FL_RawTempLabel.Text = lf_vals{3}; app.FL_TDiffLabel.Text = lf_vals{4}; app.FL_PSILapLabel.Text = lf_vals{5}; app.FL_AdjLabel.Text = lf_vals{6};
            
            % FR (Front Right) assignments using original FR_ property names
            rf_vals = calcQuadData(df.RFMaxP(hotIdx), df.RFEndP(coldIdx), df.RFIn(hotIdx), df.RFMid(hotIdx), df.RFOut(hotIdx), numLaps, ambC, trkC, targ);
            app.FR_ColdLabel.Text = rf_vals{1}; app.FR_HotLabel.Text = rf_vals{2}; app.FR_RawTempLabel.Text = rf_vals{3}; app.FR_TDiffLabel.Text = rf_vals{4}; app.FR_PSILapLabel.Text = rf_vals{5}; app.FR_AdjLabel.Text = rf_vals{6};
            
            % RL (Rear Left) assignments using original RL_ property names
            lr_vals = calcQuadData(df.LRMaxP(hotIdx), df.LREndP(coldIdx), df.LRIn(hotIdx), df.LRMid(hotIdx), df.LROut(hotIdx), numLaps, ambC, trkC, targ);
            app.RL_ColdLabel.Text = lr_vals{1}; app.RL_HotLabel.Text = lr_vals{2}; app.RL_RawTempLabel.Text = lr_vals{3}; app.RL_TDiffLabel.Text = lr_vals{4}; app.RL_PSILapLabel.Text = lr_vals{5}; app.RL_AdjLabel.Text = lr_vals{6};
            
            % RR (Rear Right) assignments using original RR_ property names
            rr_vals = calcQuadData(df.RRMaxP(hotIdx), df.RREndP(coldIdx), df.RRIn(hotIdx), df.RRMid(hotIdx), df.RROut(hotIdx), numLaps, ambC, trkC, targ);
            app.RR_ColdLabel.Text = rr_vals{1}; app.RR_HotLabel.Text = rr_vals{2}; app.RR_RawTempLabel.Text = rr_vals{3}; app.RR_TDiffLabel.Text = rr_vals{4}; app.RR_PSILapLabel.Text = rr_vals{5}; app.RR_AdjLabel.Text = rr_vals{6};
        end        
        
        % DAY SUMMARY BUTTON
        function DaySummaryButtonPushed(app, event)
            if isempty(app.DataTable)
                uialert(app.UIFigure, 'Please load a CSV file first.', 'Missing Data');
                return;
            end
            
            if isempty(app.CarDropDown.Value) || strcmp(app.CarDropDown.Value, '-')
                uialert(app.UIFigure, 'Please select a Car and Date from the Dropdowns first.', 'Missing Input');
                return;
            end
            
            targetCar = str2double(app.CarDropDown.Value);
            targetDate = app.DateDropDown.Value;
            df = app.DataTable;
            
            carMask = df.Car == targetCar;
            if ~any(carMask)
                uialert(app.UIFigure, sprintf('No data found for Car %d.', targetCar), 'Search Error'); return;
            end
            dfCar = df(carMask, :);
            
            dayMask = strcmp(dfCar.Date, targetDate);
            dfDay = dfCar(dayMask, :);
            
            if isempty(dfDay)
                uialert(app.UIFigure, 'No data found for that specific date.', 'No Data'); return;
            end
            
            trackName = regexprep(dfDay.Location{1}, '(?i)East Harling', 'Snetterton');
            hotMask = strcmpi(strtrim(dfDay.('Hot/Cold')), 'Hot');
            dfHot = dfDay(hotMask, :);
            
            if isempty(dfHot)
                uialert(app.UIFigure, 'No "Hot" runs logged for this day yet.', 'No Data'); return;
            end
            
            % Generate time array for the X-axis
            times = datetime(strcat(dfHot.Date, {' '}, dfHot.Time), 'InputFormat', 'dd/MM/yyyy HH:mm:ss');
            sessions = strtrim(dfHot.Session);
            
            % PLOTTING
            fig = figure('Name', 'Track Thermal Analysis', 'Units', 'normalized', 'Position', [0.1 0.1 0.8 0.8]);
            
            % Top Plot: Inner vs Outer Temperature Difference (Front Tires)
            subplot(2, 1, 1); hold on; grid on;
            fl_diff = abs(dfHot.LFIn - dfHot.LFOut);
            fr_diff = abs(dfHot.RFIn - dfHot.RFOut);
            
            plot(times, fl_diff, '-o', 'LineWidth', 2, 'MarkerSize', 8, 'DisplayName', 'Front Left (\Delta T)');
            plot(times, fr_diff, '-s', 'LineWidth', 2, 'MarkerSize', 8, 'DisplayName', 'Front Right (\Delta T)');
            
            % Label points with session names (e.g., FP1, Q)
            for i = 1:height(dfHot)
                if ~isnan(fl_diff(i))
                    text(times(i), fl_diff(i) + 0.3, sessions{i}, 'FontSize', 10, 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
                end
            end
            title('Front Tire Temperature Distribution (|Inner - Outer|)', 'FontSize', 14);
            ylabel('Absolute Temp Difference (\circC)', 'FontSize', 12);
            legend('Location', 'northeast');
            
            % Bottom Plot: Hot Pressures over the day (All 4 Tires)
            subplot(2, 1, 2); hold on; grid on;
            plot(times, dfHot.LFMaxP, '-o', 'LineWidth', 2, 'DisplayName', 'Front Left');
            plot(times, dfHot.RFMaxP, '-s', 'LineWidth', 2, 'DisplayName', 'Front Right');
            plot(times, dfHot.LRMaxP, '-^', 'LineWidth', 2, 'DisplayName', 'Rear Left');
            plot(times, dfHot.RRMaxP, '-d', 'LineWidth', 2, 'DisplayName', 'Rear Right');
            
            % Draw a dashed horizontal line representing the user's Target Pressure
            yline(app.TargetPressureEditField.Value, '--k', sprintf('Target Pressure (%.1f PSI)', app.TargetPressureEditField.Value), 'LineWidth', 2, 'LabelHorizontalAlignment', 'left', 'FontSize', 11);
            
            for i = 1:height(dfHot)
                text(times(i), dfHot.LFMaxP(i) + 0.3, sessions{i}, 'FontSize', 10, 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
            end
            title('Hot Pressure Evolution over the Day', 'FontSize', 14);
            ylabel('Measured Hot Pressure (PSI)', 'FontSize', 12);
            legend('Location', 'northeast');
            
            % Format the X-axis to show clean HH:mm time
            ax1 = subplot(2, 1, 1);
            ax2 = subplot(2, 1, 2);
            xtickformat(ax1, 'HH:mm');
            xtickformat(ax2, 'HH:mm');
            xlabel(ax1, 'Time of Day', 'FontSize', 12);
            xlabel(ax2, 'Time of Day', 'FontSize', 12);
        end
    end

    %% 5. THERMAL REGRESSION & UI INITIALIZATION
    methods (Access = private)
        
        % THERMAL REGRESSION BUTTON
      function ThermalRegressionButtonPushed(app, event)
            if isempty(app.DataTable); uialert(app.UIFigure, 'Load data first.', 'Error'); return; end
            
            targetCar = str2double(app.CarDropDown.Value);
            targetDate = app.DateDropDown.Value;
            
            df = app.DataTable;
            rowIdx = find(df.Car == targetCar & strcmp(df.Date, targetDate), 1);
            if isempty(rowIdx); uialert(app.UIFigure, 'Please select a valid Car/Date first.', 'Error'); return; end
            
            trackName = df.Location{rowIdx};
            allTrackMask = strcmpi(df.Location, trackName) & strcmpi(strtrim(df.('Hot/Cold')), 'Hot');
            dfTrack = df(allTrackMask, :);
            
            if isempty(dfTrack); uialert(app.UIFigure, 'No Hot runs found.', 'Error'); return; end
            
            fig = figure('Name', 'Thermodynamic Expansion Analysis', 'Units', 'normalized', 'Position', [0.1 0.1 0.8 0.8]);
            prettyName = regexprep(trackName, '(?i)East Harling', 'Snetterton');
            sgtitle(['Tire Thermal Expansion: \DeltaP vs \DeltaT (' prettyName ')'], 'FontSize', 16, 'FontWeight', 'bold');
            
            quads = {'LF', 'RF', 'LR', 'RR'};
            plotIdx = [1, 2, 3, 4]; 
            colors = {'r', 'b', 'g', 'k'};
            
            for q = 1:length(quads)
                qName = quads{q};
                ax = subplot(2, 2, plotIdx(q)); hold(ax, 'on'); grid(ax, 'on');
                
                x_deltaT = []; y_deltaP = [];
                
                for k = 1:height(dfTrack)
                    currRow = find(strcmp(df.Date, dfTrack.Date(k)) & strcmp(df.Time, dfTrack.Time(k)) & df.Car == dfTrack.Car(k));
                    cIdx = [];
                    for j = (currRow-1):-1:max(1, currRow-30)
                        if df.Car(j) == dfTrack.Car(k) && strcmpi(strtrim(string(df.('Hot/Cold'){j})), 'Cold')
                            cIdx = j; break;
                        end
                    end
                    if ~isempty(cIdx)
                        % Physics: delta P = P_hot - P_cold
                        % Physics: delta T = T_avg_hot - T_baseline_cold
                        p_cold = df.([qName 'EndP'])(cIdx);
                        p_hot = df.([qName 'MaxP'])(currRow);
                        t_cold = (0.7 * df.AmbT(cIdx)) + (0.3 * df.TrackT(cIdx));
                        t_hot = mean([df.([qName 'In'])(currRow), df.([qName 'Mid'])(currRow), df.([qName 'Out'])(currRow)], 'omitnan');
                        
                        if (t_hot - t_cold) > 2 && (p_hot - p_cold) > 0.5
                            x_deltaT(end+1) = t_hot - t_cold;
                            y_deltaP(end+1) = p_hot - p_cold;
                        end
                    end
                end
                
                if length(x_deltaT) > 2
                    % Remove extreme outliers
                    mu = mean(y_deltaP ./ x_deltaT); sigma = std(y_deltaP ./ x_deltaT);
                    validIdx = abs((y_deltaP ./ x_deltaT) - mu) <= (2 * sigma);
                    x_clean = x_deltaT(validIdx);
                    y_clean = y_deltaP(validIdx);
                    
                    scatter(ax, x_clean, y_clean, 30, colors{q}, 'filled');
                    
                    % Force intercept through origin (0 heat = 0 pressure gain)
                    mdl = fitlm(x_clean, y_clean, 'Intercept', false, 'RobustOpts', 'on'); 
                    x_fit = linspace(0, max(x_clean)*1.1, 20);
                    [y_fit, y_ci] = predict(mdl, x_fit');
                    
                    plot(ax, x_fit, y_fit, colors{q}, 'LineWidth', 2);
                    patch(ax, [x_fit, fliplr(x_fit)], [y_ci(:,1)', fliplr(y_ci(:,2)')], ...
                          colors{q}, 'FaceAlpha', 0.1, 'EdgeColor', 'none');
                          
                    % Display the exact Coefficient on the graph
                    coeff = mdl.Coefficients.Estimate;
                    text(ax, max(x_fit)*0.5, min(y_fit)+(max(y_fit)*0.2), sprintf('C_{exp} = %.3f PSI/\\circC', coeff), 'FontSize', 12, 'FontWeight', 'bold');
                end
                
                title(ax, [qName ' Quadrant']);
                xlabel(ax, 'Temp Change \DeltaT (\circC)'); ylabel(ax, 'Pressure Gain \DeltaP (PSI)');
            end
        end        
        % UI CONSTRUCTION
        % This visually draws and places every element on the screen.
        function createComponents(app)
            pathToMLAPP = fileparts(mfilename('fullpath'));
            
            app.UIFigure = uifigure('Visible', 'off');
            app.UIFigure.Position = [100 100 800 700];
            app.UIFigure.Name = 'Tire Diagnostic Dashboard';
            
            % Main UI Car Graphic
            app.Image = uiimage(app.UIFigure);
            app.Image.Position = [285 130 229 273];
            app.Image.ImageSource = fullfile(pathToMLAPP, 'HondaCivicRot.jpg');
            
            % TOP ROW CONTROLS (Y = 650)
            app.LoadCSVButton = uibutton(app.UIFigure, 'push');
            app.LoadCSVButton.ButtonPushedFcn = createCallbackFcn(app, @LoadCSVButtonPushed, true);
            app.LoadCSVButton.Position = [10 650 85 30];
            app.LoadCSVButton.Text = 'Load CSV';
            
            app.ManualEntryButton = uibutton(app.UIFigure, 'push');
            app.ManualEntryButton.ButtonPushedFcn = createCallbackFcn(app, @ManualEntryButtonPushed, true);
            app.ManualEntryButton.Position = [105 650 90 30];
            app.ManualEntryButton.Text = 'Manual Entry';
            
            app.DaySummaryButton = uibutton(app.UIFigure, 'push');
            app.DaySummaryButton.ButtonPushedFcn = createCallbackFcn(app, @DaySummaryButtonPushed, true);
            app.DaySummaryButton.Position = [205 650 90 30];
            app.DaySummaryButton.Text = 'Day Summary';
            
            app.PressureSetterButton = uibutton(app.UIFigure, 'push');
            app.PressureSetterButton.ButtonPushedFcn = createCallbackFcn(app, @PressureSetterButtonPushed, true);
            app.PressureSetterButton.Position = [305 650 110 30];
            app.PressureSetterButton.Text = 'Pressure Setter';
            
            app.ThermalRegressionButton = uibutton(app.UIFigure, 'push');
            app.ThermalRegressionButton.ButtonPushedFcn = createCallbackFcn(app, @ThermalRegressionButtonPushed, true);
            app.ThermalRegressionButton.Position = [500 570 150 24]; 
            app.ThermalRegressionButton.Text = 'Thermal Analysis';
            
            app.DataStatusLabel = uilabel(app.UIFigure);
            app.DataStatusLabel.Position = [425 650 190 30];
            app.DataStatusLabel.Text = 'Status: Booting...';
            app.DataStatusLabel.FontWeight = 'bold';
            
            app.TargetPressureLabel = uilabel(app.UIFigure);
            app.TargetPressureLabel.HorizontalAlignment = 'right';
            app.TargetPressureLabel.Position = [620 650 100 30];
            app.TargetPressureLabel.Text = 'Target Hot (PSI):';
            app.TargetPressureLabel.FontWeight = 'bold';
            
            app.TargetPressureEditField = uieditfield(app.UIFigure, 'numeric');
            app.TargetPressureEditField.Position = [730 654 40 22];
            app.TargetPressureEditField.Value = 30.0;
            
            % SECOND ROW DROPDOWNS (Y = 600)
            app.SelectCarLabel = uilabel(app.UIFigure);
            app.SelectCarLabel.Position = [20 600 40 22];
            app.SelectCarLabel.Text = 'Car:';
            app.SelectCarLabel.FontWeight = 'bold';
            
            app.CarDropDown = uidropdown(app.UIFigure);
            app.CarDropDown.Items = {'-'};
            app.CarDropDown.Position = [60 600 80 22];
            app.CarDropDown.ValueChangedFcn = createCallbackFcn(app, @CarDropDownValueChanged, true);
            
            app.SelectDateLabel = uilabel(app.UIFigure);
            app.SelectDateLabel.Position = [160 600 40 22];
            app.SelectDateLabel.Text = 'Date:';
            app.SelectDateLabel.FontWeight = 'bold';
            
            app.DateDropDown = uidropdown(app.UIFigure);
            app.DateDropDown.Items = {'-'};
            app.DateDropDown.Position = [200 600 120 22];
            app.DateDropDown.ValueChangedFcn = createCallbackFcn(app, @DateDropDownValueChanged, true);
            
            app.SelectTimeLabel = uilabel(app.UIFigure);
            app.SelectTimeLabel.Position = [340 600 40 22];
            app.SelectTimeLabel.Text = 'Time:';
            app.SelectTimeLabel.FontWeight = 'bold';
            
            app.TimeDropDown = uidropdown(app.UIFigure);
            app.TimeDropDown.Items = {'-'};
            app.TimeDropDown.Position = [380 600 100 22];
            
            app.AnalyzeSelectedButton = uibutton(app.UIFigure, 'push');
            app.AnalyzeSelectedButton.ButtonPushedFcn = createCallbackFcn(app, @AnalyzeSelectedButtonPushed, true);
            app.AnalyzeSelectedButton.Position = [500 600 150 24];
            app.AnalyzeSelectedButton.Text = 'Analyze Selected Run';
            app.AnalyzeSelectedButton.FontWeight = 'bold';
            
            % METADATA HEADER LABELS (Y = 550, 520)
            app.TrackLabel = uilabel(app.UIFigure);
            app.TrackLabel.Position = [20 550 200 22];
            app.TrackLabel.Text = 'Track: ---';
            app.TrackLabel.FontSize = 14;
            app.TrackLabel.FontWeight = 'bold';
            
            app.CarLabel = uilabel(app.UIFigure);
            app.CarLabel.Position = [220 550 150 22];
            app.CarLabel.Text = 'Car: ---';
            app.CarLabel.FontSize = 14;
            app.CarLabel.FontWeight = 'bold';
            
            app.SessionLabel = uilabel(app.UIFigure);
            app.SessionLabel.Position = [350 550 150 22];
            app.SessionLabel.Text = 'Session: ---';
            app.SessionLabel.FontSize = 14;
            
            app.DateTimeLabel = uilabel(app.UIFigure);
            app.DateTimeLabel.Position = [20 520 300 22];
            app.DateTimeLabel.Text = 'Date: --- | Time: ---';
            app.DateTimeLabel.FontSize = 13;
            
            app.EnvTempLabel = uilabel(app.UIFigure);
            app.EnvTempLabel.Position = [350 520 300 22];
            app.EnvTempLabel.Text = 'Amb Temp: --- | Track Temp: ---';
            app.EnvTempLabel.FontSize = 13;
            
            % HELPER FUNCTION TO GENERATE QUADRANTS
            % This local function draws the 4 boxes showing tire telemetry to save space
            function [pnl, cold, hot, rawt, tdiff, psilap, adj] = createQuadPanel(parent, titleStr, pos)
                pnl = uipanel(parent, 'Title', titleStr, 'Position', pos, 'FontSize', 12, 'FontWeight', 'bold');
                cold   = uilabel(pnl, 'Position', [10 105 190 22], 'Text', 'Prev Cold Press: ---', 'FontSize', 13);
                hot    = uilabel(pnl, 'Position', [10 85 190 22], 'Text', 'Meas Hot Press: ---', 'FontSize', 13);
                rawt   = uilabel(pnl, 'Position', [10 65 190 22], 'Text', 'I/M/O: --- / --- / --- C', 'FontSize', 13);
                tdiff  = uilabel(pnl, 'Position', [10 45 190 22], 'Text', '|T-Diff| In->Out: ---', 'FontSize', 13);
                psilap = uilabel(pnl, 'Position', [10 25 190 22], 'Text', 'Press Rise/Lap: ---', 'FontSize', 13);
                adj    = uilabel(pnl, 'Position', [10 5 190 22], 'Text', 'Adj Target Cold: ---', 'FontSize', 13, 'FontWeight', 'bold', 'FontColor', [0 0.45 0.74]);
            end
            
            % Execute the helper to create FL, FR, RL, and RR displays
            [app.FL_Panel, app.FL_ColdLabel, app.FL_HotLabel, app.FL_RawTempLabel, app.FL_TDiffLabel, app.FL_PSILapLabel, app.FL_AdjLabel] = ...
                createQuadPanel(app.UIFigure, 'FRONT LEFT (FL)', [40 290 220 160]);
                
            [app.FR_Panel, app.FR_ColdLabel, app.FR_HotLabel, app.FR_RawTempLabel, app.FR_TDiffLabel, app.FR_PSILapLabel, app.FR_AdjLabel] = ...
                createQuadPanel(app.UIFigure, 'FRONT RIGHT (FR)', [540 290 220 160]);
                
            [app.RL_Panel, app.RL_ColdLabel, app.RL_HotLabel, app.RL_RawTempLabel, app.RL_TDiffLabel, app.RL_PSILapLabel, app.RL_AdjLabel] = ...
                createQuadPanel(app.UIFigure, 'REAR LEFT (RL)', [40 110 220 160]);
                
            [app.RR_Panel, app.RR_ColdLabel, app.RR_HotLabel, app.RR_RawTempLabel, app.RR_TDiffLabel, app.RR_PSILapLabel, app.RR_AdjLabel] = ...
                createQuadPanel(app.UIFigure, 'REAR RIGHT (RR)', [540 110 220 160]);
                
            app.UIFigure.Visible = 'on'; % Finally, display the app to the user
        end
    end

    %% 6. APP LIFECYCLE (CONSTRUCTOR / DESTRUCTOR)
    methods (Access = public)
        % This runs the moment you type TirePressureApp in the command window
        function app = TirePressureApp
            createComponents(app)        % Draw the UI
            registerApp(app, app.UIFigure) % Register it with MATLAB
            startupFcn(app);             % Load your data
            if nargout == 0
                clear app
            end
        end
        % This runs when the app is closed (cleans up memory)
        function delete(app)
            delete(app.UIFigure)
        end
    end
end