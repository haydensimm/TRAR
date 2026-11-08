// =====================================================
// Zebrafish Heartbeat Counter - BATCH VERSION
// Processes every video in a chosen input folder
// (e.g. on an external drive) and saves the master CSV
// and trace PNGs to a chosen output folder (e.g. internal drive).
//
// For each video you are asked to draw a rectangle
// around the ventricle. The trace is then shown and you choose to:
//   - accept it and move on to the next video,
//   - redraw the ventricle and re-analyze the same video, or
//   - skip the video (nothing is saved for it).
// =====================================================

// ---------------- USER SETTINGS ----------------

// Video frame rate (applies to ALL videos in the batch)
fps = 30;

// Peak detection threshold (lower = more sensitive)
thresholdFraction = 0.20;

// Minimum time between beats (seconds); 0.25 s = max 240 BPM
minBeatInterval = 0.25;

// Smoothing window (frames either side); 3 = 7-frame moving average
smoothWindow = 3;

// Ask for a comment after each video? (true / false)
askForComments = true;

// ---------------- CHOOSE FOLDERS ----------------

inputDir = getDirectory("Choose the INPUT folder containing the videos");
outputDir = getDirectory("Choose the OUTPUT folder for CSV and traces");

traceDir = outputDir + "HR Traces" + File.separator;
File.makeDirectory(traceDir);

masterFile = outputDir + "master_heart_results.csv";

// Header (only written if the CSV does not exist yet)
if (!File.exists(masterFile)) {
    File.saveString(
        "File,FPS,Frames,Duration_sec,Beats,BPM,Comments\n",
        masterFile
    );
}

// ---------------- BUILD VIDEO LIST ----------------

allFiles = getFileList(inputDir);
videos = newArray(allFiles.length);
nVideos = 0;

for (k = 0; k < allFiles.length; k++) {
    lowerName = toLowerCase(String.trim(allFiles[k]));
    isVid = 0;
    if (endsWith(lowerName, ".mov")) isVid = 1;
    if (endsWith(lowerName, ".mp4")) isVid = 1;
    if (endsWith(lowerName, ".avi")) isVid = 1;
    if (endsWith(lowerName, ".tif")) isVid = 1;
    if (endsWith(lowerName, ".tiff")) isVid = 1;
    if (isVid == 1) {
        videos[nVideos] = allFiles[k];
        nVideos++;
    }
}

if (nVideos == 0) {
    msg = "No video files (.avi, .mov, .mp4, .tif, .tiff) found in:\n" +
          inputDir + "\n\nItems the macro can see there: " + allFiles.length + "\n";
    for (k = 0; k < minOf(allFiles.length, 10); k++)
        msg = msg + allFiles[k] + "\n";
    exit(msg);
}

videos = Array.trim(videos, nVideos);

print("\\Clear");
print("Found " + nVideos + " videos in " + inputDir);
print("================================");

// ---------------- MAIN LOOP ----------------

for (v = 0; v < nVideos; v++) {

    fileName = videos[v];
    dotIndex = lastIndexOf(fileName, ".");
    baseName = substring(fileName, 0, dotIndex);

    print("Processing (" + (v + 1) + "/" + nVideos + "): " + fileName);

    // Open video
    // Bio-Formats with preset options (suppresses the import dialog)
    // (forward slashes avoid Windows backslash problems in the options string)
    openPath = replace(inputDir + fileName, "\\", "/");
    run("Movie (FFMPEG)...",
        "choose=[" + openPath + "] first_frame=0 last_frame=-1");
    n = nSlices();

    if (n < 5) {
        print("  SKIPPED (fewer than 5 frames): " + fileName);
        close("*");
        continue;
    }

    videoID = getImageID();
    attempt = 0;
    accepted = false;
    skipped = false;
    comment = "";

    // Repeat ROI drawing + analysis until the user accepts or skips
    while (!accepted && !skipped) {

        attempt++;
        selectImage(videoID);
        setSlice(1);

        // Ask the user to define the heart region
        if (attempt == 1) {
            waitForUser(
                "Video " + (v + 1) + " of " + nVideos + ": " + fileName + "\n \n" +
                "Draw a rectangle around the ventricle/heart,\n" +
                "then click OK."
            );
        } else {
            waitForUser(
                "Video " + (v + 1) + " of " + nVideos + ": " + fileName +
                "  (attempt " + attempt + ")\n \n" +
                "Redraw the rectangle around the ventricle/heart\n" +
                "(the previous box is still there; you can drag/resize it\n" +
                "or draw a new one), then click OK."
            );
        }

        if (selectionType() == -1) {
            print("  SKIPPED (no ROI drawn): " + fileName);
            skipped = true;
            break;
        }

        // Arrays
        time = newArray(n);
        signal = newArray(n);
        smoothSignal = newArray(n);

        run("Clear Results");
        run("Set Measurements...", "mean redirect=None decimal=3");

        // ---------------- MEASURE SIGNAL ----------------
        for (i = 1; i <= n; i++) {
            setSlice(i);
            run("Measure");
            signal[i-1] = getResult("Mean", i-1);
            time[i-1] = (i-1) / fps;
        }
        setSlice(1);

        // ---------------- SMOOTH SIGNAL ----------------
        for (i = 0; i < n; i++) {
            sum = 0;
            count = 0;
            for (j = -smoothWindow; j <= smoothWindow; j++) {
                idx = i + j;
                if (idx >= 0 && idx < n) {
                    sum += signal[idx];
                    count++;
                }
            }
            smoothSignal[i] = sum / count;
        }

        // ---------------- SIGNAL RANGE ----------------
        maxVal = smoothSignal[0];
        minVal = smoothSignal[0];

        for (i = 1; i < n; i++) {
            if (smoothSignal[i] > maxVal) maxVal = smoothSignal[i];
            if (smoothSignal[i] < minVal) minVal = smoothSignal[i];
        }

        signalRange = maxVal - minVal;
        threshold = minVal + thresholdFraction * signalRange;
        prominenceThreshold = 0.07 * signalRange;

        // ---------------- PEAK DETECTION ----------------
        minDistance = round(minBeatInterval * fps);
        searchWindow = round(0.20 * fps);

        beats = 0;
        lastPeak = -minDistance;
        peakTimes = newArray(n);
        peakValues = newArray(n);
        peakCount = 0;

        for (i = 2; i < n-2; i++) {

            isLocalMax =
                smoothSignal[i] > smoothSignal[i-1] &&
                smoothSignal[i] >= smoothSignal[i+1] &&
                smoothSignal[i] > smoothSignal[i-2] &&
                smoothSignal[i] >= smoothSignal[i+2];

            isStrongEnough = smoothSignal[i] > threshold;

            leftMin = smoothSignal[i];
            rightMin = smoothSignal[i];

            for (j = 1; j <= searchWindow; j++) {
                if (i-j >= 0) {
                    if (smoothSignal[i-j] < leftMin) leftMin = smoothSignal[i-j];
                }
                if (i+j < n) {
                    if (smoothSignal[i+j] < rightMin) rightMin = smoothSignal[i+j];
                }
            }

            localBaseline = maxOf(leftMin, rightMin);
            isProminent = (smoothSignal[i] - localBaseline) > prominenceThreshold;
            farEnough = (i - lastPeak) >= minDistance;

            if (isLocalMax && isStrongEnough && isProminent && farEnough) {
                beats++;
                lastPeak = i;
                peakTimes[peakCount] = time[i];
                peakValues[peakCount] = smoothSignal[i];
                peakCount++;
            }
        }

        // ---------------- BPM ----------------
        duration_sec = (n - 1) / fps;

        if (peakCount >= 2) {
            beatDuration = peakTimes[peakCount-1] - peakTimes[0];
            bpm = ((peakCount-1) / beatDuration) * 60;
        } else {
            bpm = 0;
        }

        // ---------------- PLOT TRACE ----------------
        peakTimes = Array.trim(peakTimes, peakCount);
        peakValues = Array.trim(peakValues, peakCount);

        Plot.create(baseName + "_trace", "Time (s)", "Mean Intensity", time, smoothSignal);

        if (peakCount > 0) {
            Plot.setColor("red");
            Plot.add("circle", peakTimes, peakValues);
        }

        Plot.show();
        plotID = getImageID();

        // ---------------- REVIEW TRACE ----------------
        // The trace stays on screen behind this dialog.
        // (Pressing Cancel aborts the whole macro.)
        Dialog.create("Review trace: " + fileName);
        Dialog.addMessage(
            "Video " + (v + 1) + " of " + nVideos + "   (attempt " + attempt + ")\n" +
            "Beats: " + beats + "     BPM: " + d2s(bpm, 1)
        );
        Dialog.addChoice(
            "What next?",
            newArray(
                "Accept and go to next video",
                "Redraw ventricle and re-analyze",
                "Skip this video (do not save)"
            ),
            "Accept and go to next video"
        );
        if (askForComments) {
            Dialog.addString("Comments (saved if you accept):", comment, 40);
        }
        Dialog.show();

        choice = Dialog.getChoice();
        if (askForComments) {
            comment = Dialog.getString();
            // Commas would break the CSV columns
            comment = replace(comment, ",", ";");
        }

        if (startsWith(choice, "Accept")) {
            // Save the accepted trace PNG
            selectImage(plotID);
            saveAs("PNG", traceDir + baseName + "_trace.png");

            // ---------------- APPEND TO MASTER CSV ----------------
            line =
                baseName + "," +
                fps + "," +
                n + "," +
                d2s(duration_sec, 3) + "," +
                beats + "," +
                d2s(bpm, 1) + "," +
                comment + "\n";

            File.append(line, masterFile);

            print("  Beats: " + beats + "   BPM: " + d2s(bpm, 1) +
                  "   (accepted on attempt " + attempt + ")");
            accepted = true;

        } else if (startsWith(choice, "Redraw")) {
            print("  Attempt " + attempt + " rejected (BPM " + d2s(bpm, 1) +
                  "); redrawing ROI");
            // Close only the trace; keep the video open
            selectImage(plotID);
            close();
            selectImage(videoID);

        } else {
            print("  SKIPPED by user: " + fileName);
            skipped = true;
        }
    }

    // Close the video and plot before moving on
    close("*");
}

print("================================");
print("Batch complete.");
print("CSV: " + masterFile);
print("Traces: " + traceDir);

showMessage(
    "Batch complete",
    "Processed " + nVideos + " videos.\n\n" +
    "CSV:\n" + masterFile + "\n\nTraces:\n" + traceDir
);
