//======================================================
// Zebrafish Thyroid GFP Quantification
// Automatic follicle detection + combined CTCF
// Corrected ROI Manager selection handling
//======================================================


//------------------------------------------------------
// USER SETTINGS
//------------------------------------------------------

// Minimum detected object area.
// This removes tiny bright specks but does not set
// a fixed fluorescence-intensity threshold.
minParticleSize = 10;


//------------------------------------------------------
// SELECT INPUT FOLDER
//------------------------------------------------------

inputDir = getDirectory("Choose TIFF image folder");

resultsDir = inputDir + "Results/";
overlayDir = inputDir + "Detection_Overlays/";
maskDir = inputDir + "Detection_Masks/";

File.makeDirectory(resultsDir);
File.makeDirectory(overlayDir);
File.makeDirectory(maskDir);


//------------------------------------------------------
// RESULTS FILE
//------------------------------------------------------

csv = resultsDir + "Thyroid_GFP_AutoDetection_CTCF_results.csv";

File.saveString(
    "Image,NumParticles,ThyroidArea,ThyroidMean," +
    "ThyroidIntDen,BackgroundArea,BackgroundMean,CTCF\n",
    csv
);


//------------------------------------------------------
// MEASUREMENT SETTINGS
//------------------------------------------------------

run("Set Measurements...", "area mean integrated decimal=3");

setOption("BlackBackground", true);

list = getFileList(inputDir);


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


    //--------------------------------------------------
    // USER-DRAWN SEARCH ROI
    //--------------------------------------------------

    waitForUser(
        "Thyroid search region",
        "Draw one ROI around all visible thyroid follicles.\n\n" +
        "Include every follicle that should be detected, but avoid\n" +
        "unrelated bright structures where possible.\n\n" +
        "Click OK when the search ROI is ready."
    );

    // Add and explicitly select the search ROI
    roiManager("Add");

    searchIndex = roiManager("count") - 1;

    roiManager("Select", searchIndex);
    roiManager("Rename", "Search_ROI");


    //--------------------------------------------------
    // CREATE FULL-SIZE SEGMENTATION COPY
    //--------------------------------------------------

    selectWindow(originalTitle);
    run("Select None");

    segmentationTitle = "SEGMENTATION_" + i;

    run("Duplicate...", "title=" + segmentationTitle);

    selectWindow(segmentationTitle);

    // Apply search ROI to duplicate
    roiManager("Select", searchIndex);

    setBackgroundColor(0, 0, 0);
    run("Clear Outside");


    //--------------------------------------------------
    // AUTOMATIC THRESHOLD
    //--------------------------------------------------
    // Triangle calculates a new threshold for each image.

    setAutoThreshold("Triangle dark");
    run("Convert to Mask");


    //--------------------------------------------------
    // DETECT PARTICLES
    //--------------------------------------------------

    roiCountBeforeParticles = roiManager("count");

    run(
        "Analyze Particles...",
        "size=" + minParticleSize +
        "-Infinity circularity=0.00-1.00 show=Nothing add"
    );

    roiCountAfterParticles = roiManager("count");

    numParticles =
        roiCountAfterParticles - roiCountBeforeParticles;


    //--------------------------------------------------
    // HANDLE IMAGES WITH NO DETECTIONS
    //--------------------------------------------------

    if (numParticles == 0) {

        saveAs(
            "Tiff",
            maskDir + name + "_NO_DETECTION_mask.tif"
        );

        close();

        selectWindow(originalTitle);
        close();

        File.append(
            originalTitle +
            ",0,NA,NA,NA,NA,NA,NA\n",
            csv
        );

        roiManager("Reset");
        run("Clear Results");

        print("WARNING: No particles detected in " + originalTitle);

        continue;
    }


    //--------------------------------------------------
    // SAVE SEGMENTATION MASK
    //--------------------------------------------------

    saveAs(
        "Tiff",
        maskDir + name + "_detection_mask.tif"
    );


    //--------------------------------------------------
    // COMBINE ALL DETECTED PARTICLES
    //--------------------------------------------------

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

    // Explicitly select it before renaming
    roiManager("Select", combinedIndex);
    roiManager("Rename", "Detected_Thyroid");


    //--------------------------------------------------
    // CLOSE SEGMENTATION IMAGE
    //--------------------------------------------------

    close();


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


    //--------------------------------------------------
    // USER-DRAWN BACKGROUND ROI
    //--------------------------------------------------

    run("Select None");

    waitForUser(
        "Background region",
        "Draw a background ROI in a region without GFP-positive\n" +
        "thyroid follicles.\n\n" +
        "Choose a representative nearby region and avoid unrelated\n" +
        "bright structures.\n\n" +
        "Click OK when the background ROI is ready."
    );

    run("Measure");

    backgroundArea = getResult("Area", nResults - 1);
    backgroundMean = getResult("Mean", nResults - 1);

    // Add and explicitly select background ROI
    roiManager("Add");

    backgroundIndex = roiManager("count") - 1;

    roiManager("Select", backgroundIndex);
    roiManager("Rename", "Background");


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
        numParticles + "," +
        thyroidArea + "," +
        thyroidMean + "," +
        thyroidIntDen + "," +
        backgroundArea + "," +
        backgroundMean + "," +
        ctcf + "\n";

    File.append(line, csv);


    //--------------------------------------------------
    // CREATE OVERLAY COPY
    //--------------------------------------------------

    selectWindow(originalTitle);
    run("Select None");

    overlayTitle = "OVERLAY_" + i;

    run("Duplicate...", "title=" + overlayTitle);

    selectWindow(overlayTitle);
    run("RGB Color");

    // Blue = manually drawn search region
    roiManager("Select", searchIndex);
    setColor("blue");
    run("Draw");

    // Red = automatically detected thyroid
    roiManager("Select", combinedIndex);
    setColor("red");
    run("Draw");

    // Green = manually drawn background region
    roiManager("Select", backgroundIndex);
    setColor("green");
    run("Draw");

    saveAs(
        "Tiff",
        overlayDir + name + "_detection_overlay.tif"
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