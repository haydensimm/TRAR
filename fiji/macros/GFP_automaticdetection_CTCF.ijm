//======================================================
// Zebrafish Thyroid GFP Quantification
// Automatic follicle detection + combined CTCF
//
// v2 changes:
//  - Search ROI and background ROI can be drawn as a
//    rectangle OR freehand (chosen at start, and can be
//    switched on any redraw)
//  - After detection you see the result and can Accept,
//    Redraw (rectangle), Redraw (freehand) or Skip image
//  - Background ROI is also shown and can be redrawn
//  - Choose the output folder; if Results/, masks, overlays
//    or the CSV already exist, new results are ADDED to them
//  - Tissue type (follicles / brain / gills) is confirmed in
//    the check dialogs and saved as a "Tissue" CSV column
//======================================================


// Global variables (must be declared with "var" so the
// helper functions at the bottom can use them)
var tissueOptions = newArray("follicles", "brain", "gills");
var tissueChoice = "follicles";   // remembered between images
var commentText = "";             // cleared for each new image


//------------------------------------------------------
// USER SETTINGS
//------------------------------------------------------

// Minimum detected object area.
// This removes tiny bright specks but does not set
// a fixed fluorescence-intensity threshold.
minParticleSize = 10;


//------------------------------------------------------
// STARTUP DIALOG: DEFAULT ROI SHAPES
//------------------------------------------------------

shapeChoices = newArray("Rectangle", "Freehand");

Dialog.create("ROI settings");
Dialog.addChoice("Search ROI shape (default)", shapeChoices, "Freehand");
Dialog.addChoice("Background ROI shape (default)", shapeChoices, "Rectangle");
Dialog.show();

defaultSearchShape = Dialog.getChoice();
defaultBgShape = Dialog.getChoice();


//------------------------------------------------------
// SELECT INPUT FOLDER
//------------------------------------------------------

inputDir = getDirectory("Choose TIFF image folder");


//------------------------------------------------------
// SELECT OUTPUT FOLDER
//------------------------------------------------------
// Pick a new or existing folder. If it already contains
// Results / Detection_Overlays / Detection_Masks from a
// previous run, the new files and CSV rows are added to them.

outputDir = getDirectory("Choose OUTPUT folder (new or existing)");

resultsDir = outputDir + "Results/";
overlayDir = outputDir + "Detection_Overlays/";
maskDir = outputDir + "Detection_Masks/";

// makeDirectory does nothing harmful if the folder exists
File.makeDirectory(resultsDir);
File.makeDirectory(overlayDir);
File.makeDirectory(maskDir);


//------------------------------------------------------
// RESULTS FILE (create, or append to existing)
//------------------------------------------------------

csv = resultsDir + "Thyroid_GFP_AutoDetection_CTCF_results.csv";

csvHeader =
    "Image,Tissue,NumParticles,ThyroidArea,ThyroidMean," +
    "ThyroidIntDen,BackgroundArea,BackgroundMean,CTCF,Comments";

// Header used by the previous version (no Comments column)
csvHeaderNoComments =
    "Image,Tissue,NumParticles,ThyroidArea,ThyroidMean," +
    "ThyroidIntDen,BackgroundArea,BackgroundMean,CTCF";

if (File.exists(csv)) {

    existingText = File.openAsString(csv);

    if (lengthOf(existingText) == 0) {

        File.saveString(csvHeader + "\n", csv);

    } else {

        existingLines = split(existingText, "\n");
        existingHeader = replace(existingLines[0], "\r", "");

        // Upgrade a CSV from the previous version by adding the
        // Comments column to the header (old rows stay as they are,
        // with an empty comment).
        if (existingHeader == csvHeaderNoComments) {

            firstNewline = indexOf(existingText, "\n");

            if (firstNewline < 0)
                existingText = csvHeader + "\n";
            else
                existingText = csvHeader + substring(existingText, firstNewline);

            File.saveString(existingText, csv);

            existingHeader = csvHeader;

            print("Added Comments column to existing CSV header.");
        }

        if (existingHeader != csvHeader) {
            exit(
                "The existing CSV has different columns:\n" +
                csv + "\n\n" +
                "Existing header:\n" + existingHeader + "\n\n" +
                "Expected header:\n" + csvHeader + "\n\n" +
                "Add a 'Tissue' column after 'Image' in the old file,\n" +
                "or choose a different output folder."
            );
        }

        print("Adding to existing CSV: " + csv);
    }

} else {

    File.saveString(csvHeader + "\n", csv);
}


//------------------------------------------------------
// MEASUREMENT SETTINGS
//------------------------------------------------------

run("Set Measurements...", "area mean integrated decimal=3");

setOption("BlackBackground", true);

list = getFileList(inputDir);

// Shapes persist from one image to the next once changed
searchShape = defaultSearchShape;
bgShape = defaultBgShape;


//======================================================
// PROCESS IMAGES
//======================================================

for (i = 0; i < list.length; i++) {

    //--------------------------------------------------
    // ONLY PROCESS TIFF FILES
    //--------------------------------------------------

    lowerName = toLowerCase(list[i]);

    if (!(endsWith(lowerName, ".tif") ||
          endsWith(lowerName, ".tiff")))
        continue;


    //--------------------------------------------------
    // OPEN ORIGINAL IMAGE
    //--------------------------------------------------

    open(inputDir + list[i]);

    originalTitle = getTitle();

    name = originalTitle;
    name = replace(name, ".tiff", "");
    name = replace(name, ".Tiff", "");
    name = replace(name, ".TIFF", "");
    name = replace(name, ".tif", "");
    name = replace(name, ".Tif", "");
    name = replace(name, ".TIF", "");

    roiManager("Reset");
    run("Clear Results");
    run("Select None");

    segmentationTitle = "SEGMENTATION_" + i;

    commentText = "";

    searchAccepted = false;
    skipImage = false;
    numParticles = 0;
    searchIndex = 0;
    combinedIndex = -1;


    //==================================================
    // STEP 1: SEARCH ROI -> DETECTION -> CONFIRM/REDRAW
    //==================================================

    while (!searchAccepted && !skipImage) {

        selectWindow(originalTitle);
        run("Remove Overlay");
        roiManager("Reset");
        run("Clear Results");

        //----------------------------------------------
        // USER-DRAWN SEARCH ROI
        //----------------------------------------------

        drawROI(
            "Thyroid search region (" + searchShape + ")",
            "Draw one " + toLowerCase(searchShape) + " ROI around all visible " +
            "thyroid follicles.\n\n" +
            "Include every follicle that should be detected, but avoid\n" +
            "unrelated bright structures where possible.\n\n" +
            "Click OK when the search ROI is ready.",
            searchShape
        );

        // Add and explicitly select the search ROI (index 0)
        roiManager("Add");
        searchIndex = roiManager("count") - 1;
        roiManager("Select", searchIndex);
        roiManager("Rename", "Search_ROI");


        //----------------------------------------------
        // CREATE FULL-SIZE SEGMENTATION COPY
        //----------------------------------------------

        selectWindow(originalTitle);
        run("Select None");

        run("Duplicate...", "title=" + segmentationTitle);
        selectWindow(segmentationTitle);

        // Apply search ROI to duplicate
        roiManager("Select", searchIndex);

        setBackgroundColor(0, 0, 0);
        run("Clear Outside");


        //----------------------------------------------
        // AUTOMATIC THRESHOLD
        //----------------------------------------------
        // Triangle calculates a new threshold for each image.

        setAutoThreshold("Triangle dark");
        run("Convert to Mask");


        //----------------------------------------------
        // DETECT PARTICLES
        //----------------------------------------------

        roiCountBeforeParticles = roiManager("count");

        run(
            "Analyze Particles...",
            "size=" + minParticleSize +
            "-Infinity circularity=0.00-1.00 show=Nothing add"
        );

        roiCountAfterParticles = roiManager("count");

        numParticles =
            roiCountAfterParticles - roiCountBeforeParticles;

        combinedIndex = -1;


        //----------------------------------------------
        // COMBINE ALL DETECTED PARTICLES
        //----------------------------------------------

        if (numParticles > 0) {

            particleIndexes = newArray(numParticles);

            for (p = 0; p < numParticles; p++) {
                particleIndexes[p] = roiCountBeforeParticles + p;
            }

            if (numParticles == 1) {

                roiManager("Select", particleIndexes[0]);

            } else {

                roiManager("Select", particleIndexes);
                roiManager("Combine");
            }

            // Add the combined thyroid selection
            roiManager("Add");

            combinedIndex = roiManager("count") - 1;

            roiManager("Select", combinedIndex);
            roiManager("Rename", "Detected_Thyroid");
        }


        //----------------------------------------------
        // SHOW RESULT ON ORIGINAL IMAGE
        //----------------------------------------------
        // Blue = search ROI, Red = detected thyroid

        selectWindow(originalTitle);
        showOverlays(searchIndex, combinedIndex, -1);


        //----------------------------------------------
        // CONFIRM OR REDRAW
        //----------------------------------------------

        if (numParticles == 0) {
            msg = "No particles were detected in this search region.\n\n" +
                  "Accept = record this image as 'no detection'.\n" +
                  "Or redraw the search ROI.";
        } else {
            msg = "Blue = search ROI\n" +
                  "Red = detected thyroid (" + numParticles + " particles)\n\n" +
                  "You can zoom/inspect the image before choosing.";
        }

        choice = confirmChoice(
            "Check detection: " + originalTitle,
            msg,
            true
        );

        if (choice == "Accept") {

            searchAccepted = true;

        } else if (startsWith(choice, "Skip")) {

            skipImage = true;

            selectWindow(segmentationTitle);
            close();

        } else {

            // Redraw requested; remember chosen shape
            if (indexOf(choice, "rectangle") >= 0)
                searchShape = "Rectangle";
            else
                searchShape = "Freehand";

            selectWindow(segmentationTitle);
            close();
        }
    }


    //--------------------------------------------------
    // SKIPPED IMAGE
    //--------------------------------------------------

    if (skipImage) {

        selectWindow(originalTitle);
        close();

        appendLine(
            originalTitle + "," + tissueChoice +
            ",NA,NA,NA,NA,NA,NA,NA," + csvEscape(commentText),
            csv
        );

        roiManager("Reset");
        run("Clear Results");

        print("SKIPPED by user: " + originalTitle);

        continue;
    }


    //--------------------------------------------------
    // ACCEPTED, BUT NO DETECTIONS
    //--------------------------------------------------

    if (numParticles == 0) {

        selectWindow(segmentationTitle);

        saveAs(
            "Tiff",
            maskDir + name + "_NO_DETECTION_mask_" + tissueChoice + ".tif"
        );

        close();

        selectWindow(originalTitle);
        close();

        appendLine(
            originalTitle + "," + tissueChoice +
            ",0,NA,NA,NA,NA,NA,NA," + csvEscape(commentText),
            csv
        );

        roiManager("Reset");
        run("Clear Results");

        print("WARNING: No particles detected in " + originalTitle);

        continue;
    }


    //--------------------------------------------------
    // NOTE: the segmentation mask stays open for now and is
    // saved after the background step, because the tissue
    // (used in the filename) can still be changed in the
    // background check dialog.
    //--------------------------------------------------


    //--------------------------------------------------
    // MEASURE THYROID ON ORIGINAL IMAGE
    //--------------------------------------------------

    selectWindow(originalTitle);

    roiManager("Select", combinedIndex);

    run("Clear Results");
    run("Measure");

    thyroidArea = getResult("Area", nResults - 1);
    thyroidMean = getResult("Mean", nResults - 1);
    thyroidIntDen = getResult("IntDen", nResults - 1);


    //==================================================
    // STEP 2: BACKGROUND ROI -> CONFIRM/REDRAW
    //==================================================

    bgAccepted = false;
    backgroundIndex = -1;
    backgroundArea = 0;
    backgroundMean = 0;

    while (!bgAccepted) {

        selectWindow(originalTitle);

        // Keep blue/red overlays visible while drawing
        showOverlays(searchIndex, combinedIndex, -1);

        drawROI(
            "Background region (" + bgShape + ")",
            "Draw a " + toLowerCase(bgShape) + " background ROI in a region " +
            "without GFP-positive\nthyroid follicles.\n\n" +
            "Choose a representative nearby region and avoid unrelated\n" +
            "bright structures.\n\n" +
            "Click OK when the background ROI is ready.",
            bgShape
        );

        run("Measure");

        backgroundArea = getResult("Area", nResults - 1);
        backgroundMean = getResult("Mean", nResults - 1);

        // Add and explicitly select background ROI
        roiManager("Add");

        backgroundIndex = roiManager("count") - 1;

        roiManager("Select", backgroundIndex);
        roiManager("Rename", "Background");

        // Show all three regions
        showOverlays(searchIndex, combinedIndex, backgroundIndex);

        choice = confirmChoice(
            "Check background: " + originalTitle,
            "Blue = search ROI\n" +
            "Red = detected thyroid\n" +
            "Green = background ROI (mean = " +
            d2s(backgroundMean, 2) + ")",
            false
        );

        if (choice == "Accept") {

            bgAccepted = true;

        } else {

            if (indexOf(choice, "rectangle") >= 0)
                bgShape = "Rectangle";
            else
                bgShape = "Freehand";

            // Remove the rejected background ROI from the manager
            roiManager("Select", backgroundIndex);
            roiManager("Delete");
            backgroundIndex = -1;
        }
    }


    //--------------------------------------------------
    // CALCULATE CTCF
    //--------------------------------------------------

    ctcf =
        thyroidIntDen -
        (thyroidArea * backgroundMean);


    //--------------------------------------------------
    // SAVE RESULTS
    //--------------------------------------------------

    line =
        originalTitle + "," +
        tissueChoice + "," +
        numParticles + "," +
        thyroidArea + "," +
        thyroidMean + "," +
        thyroidIntDen + "," +
        backgroundArea + "," +
        backgroundMean + "," +
        ctcf + "," +
        csvEscape(commentText);

    appendLine(line, csv);


    //--------------------------------------------------
    // SAVE SEGMENTATION MASK (tissue added to filename)
    //--------------------------------------------------

    selectWindow(segmentationTitle);

    saveAs(
        "Tiff",
        maskDir + name + "_detection_mask_" + tissueChoice + ".tif"
    );

    close();


    //--------------------------------------------------
    // CREATE OVERLAY COPY
    //--------------------------------------------------

    selectWindow(originalTitle);
    run("Remove Overlay");
    run("Select None");

    overlayTitle = "OVERLAY_" + i;

    run("Duplicate...", "title=" + overlayTitle);

    selectWindow(overlayTitle);
    run("RGB Color");

    // Blue = search region
    roiManager("Select", searchIndex);
    setColor("blue");
    run("Draw");

    // Red = automatically detected thyroid
    roiManager("Select", combinedIndex);
    setColor("red");
    run("Draw");

    // Green = background region
    roiManager("Select", backgroundIndex);
    setColor("green");
    run("Draw");

    saveAs(
        "Tiff",
        overlayDir + name + "_detection_overlay_" + tissueChoice + ".tif"
    );

    close();


    //--------------------------------------------------
    // CLOSE ORIGINAL AND CLEAN UP
    //--------------------------------------------------

    selectWindow(originalTitle);
    close();

    roiManager("Reset");
    run("Clear Results");

    print(
        "Processed: " + originalTitle +
        " | Detected particles: " + numParticles
    );
}


//======================================================
// FINISHED
//======================================================

print("");
print("DONE");
print("Results saved to:");
print(csv);


//======================================================
// HELPER FUNCTIONS
//======================================================

// Activate the drawing tool for the requested shape and wait
// until the user has drawn a valid area selection.
// The selection is left active on the current image.
function drawROI(title, message, shape) {

    run("Select None");

    if (shape == "Rectangle")
        setTool("rectangle");
    else
        setTool("freehand");

    valid = false;

    while (!valid) {

        waitForUser(title, message);

        t = selectionType();

        // -1 = none; 5-7 = lines; 10 = point(s). Area types are
        // 0-4 (rect, oval, polygon, freehand, traced) and 9 (composite).
        if ((t >= 0 && t <= 4) || t == 9) {
            valid = true;
        } else {
            showMessage(
                "No valid ROI",
                "No area selection found.\n" +
                "Please draw a " + toLowerCase(shape) + " ROI, then click OK."
            );
        }
    }
}


// Non-blocking dialog so the image can still be zoomed/inspected.
// Returns the chosen action as a string.
function confirmChoice(title, message, allowSkip) {

    if (allowSkip)
        options = newArray("Accept",
                           "Redraw - rectangle",
                           "Redraw - freehand",
                           "Skip image (no measurement)");
    else
        options = newArray("Accept",
                           "Redraw - rectangle",
                           "Redraw - freehand");

    Dialog.createNonBlocking(title);
    Dialog.addMessage(message);
    Dialog.addChoice("Tissue", tissueOptions, tissueChoice);
    Dialog.addChoice("Action", options, "Accept");
    Dialog.addString("Comments", commentText, 40);
    Dialog.show();

    // Choices are returned in the order they were added.
    // Tissue and comment are stored globally and written to the CSV.
    tissueChoice = Dialog.getChoice();
    action = Dialog.getChoice();
    commentText = Dialog.getString();

    return action;
}


// Make free text safe for one CSV cell: remove line breaks,
// double any quotation marks, and wrap in quotes so commas
// in the comment don't create extra columns.
function csvEscape(text) {

    text = replace(text, "\r", " ");
    text = replace(text, "\n", " ");
    text = replace(text, "\"", "\"\"");

    return "\"" + text + "\"";
}


// Append one line to a text file. Reads the existing content and
// rewrites it so each row is always on its own line, even if the
// existing file (e.g. re-saved from Excel) lacks a trailing newline.
function appendLine(line, path) {

    content = "";

    if (File.exists(path))
        content = File.openAsString(path);

    if (lengthOf(content) > 0 && !endsWith(content, "\n"))
        content = content + "\n";

    File.saveString(content + line + "\n", path);
}


// Draw ROI-manager entries as coloured overlays on the active image.
// Pass -1 for any index that should not be shown.
function showOverlays(searchIdx, detectedIdx, backgroundIdx) {

    run("Remove Overlay");

    if (searchIdx >= 0) {
        roiManager("Select", searchIdx);
        run("Add Selection...", "stroke=blue width=2");
    }

    if (detectedIdx >= 0) {
        roiManager("Select", detectedIdx);
        run("Add Selection...", "stroke=red width=2");
    }

    if (backgroundIdx >= 0) {
        roiManager("Select", backgroundIdx);
        run("Add Selection...", "stroke=green width=2");
    }

    roiManager("Deselect");
    run("Select None");
}
