// @todo: deprecate windows includes

#include <winstd.H>

#include <iostream>
#include <iomanip>
#include <sstream>

#ifndef WIN32
#include <unistd.h>
#endif

#include <CArena.H>
#include <REAL.H>
#include <Utility.H>
#include <IntVect.H>
#include <Box.H>
#include <Amr.H>
#include <ParmParse.H>
#include <ParallelDescriptor.H>
#include <AmrLevel.H>
#include <Geometry.H>
#include <MultiFab.H>
#include <MemInfo.H>
#include <Nyx.H>

#ifdef REEBER
#ifdef IN_SITU
#include <boxlib_in_situ_analysis.H>
#elif defined IN_TRANSIT
#include <InTransitAnalysis.H>
#endif
#endif

#include "Nyx_output.H"

std::string inputs_name = "";

#ifdef GIMLET
#include <DoGimletAnalysis.H>
#include <postprocess_tau_fields.H>
#include <fftw3-mpi.h>
#include <MakeFFTWBoxes.H>
#endif


#ifdef FAKE_REEBER
#include <unistd.h>
namespace
{
  void runInSituAnalysis(const MultiFab& simulation_data, const Geometry &geometry, int time_step)
  {
    if(ParallelDescriptor::IOProcessor()) {
      std::cout << "<<||||||||||>> _in runInSituAnalysis:  faking it." << std::endl;
    }
    BoxLib::USleep(0.42);  // ---- seconds
  }

  void initInSituAnalysis()
  {
    if(ParallelDescriptor::IOProcessor()) {
      std::cout << "|||||||||||||| _in initInSituAnalysis:  faking it." << std::endl;
      std::cout << "|||||||||||||| nProcs (np all comp sidecar) ="
		<< ParallelDescriptor::NProcs() << "  "
		<< ParallelDescriptor::NProcsAll() << "  "
		<< ParallelDescriptor::NProcsComp() << "  "
		<< ParallelDescriptor::NProcsSidecar() << "  "
                << std::endl;
    }
  }

}
#endif

const int NyxHaloFinderSignal(42);
const int resizeSignal(43);
const int GimletSignal(55);
const int quitSignal(-44);


// This anonymous namespace defines the workflow of the sidecars when running
// in in-transit mode.
namespace
{
#ifdef IN_TRANSIT
  static void ResizeSidecars(int newSize) {
#ifdef BL_USE_MPI
    // ---- everyone meets here
    ParallelDescriptor::Barrier(ParallelDescriptor::CommunicatorAll());
    if(ParallelDescriptor::IOProcessor()) {
      std::cout << ParallelDescriptor::MyProcAll() << ":  _in ResizeSidecars::newSize = "
                << newSize << std::endl;
    }
    ParallelDescriptor::Barrier(ParallelDescriptor::CommunicatorAll());
    ParallelDescriptor::SetNProcsSidecars(newSize);
#endif
  }


  static int SidecarEventLoop() {

#ifdef BL_USE_MPI
    BL_ASSERT(NyxHaloFinderSignal != quitSignal);

    bool finished(false);
    int sidecarSignal(-1);
    int whichSidecar(0);  // ---- this is sidecar zero
    if(ParallelDescriptor::IOProcessor()) {
      std::cout << "SSSSSSSS:  Starting SidecarEventLoop." << std::endl;
    }

    while ( ! finished) {
        // ---- Receive the sidecarSignal from the compute group.
        if(ParallelDescriptor::IOProcessor()) {
          std::cout << "SSSSSSSS:  waiting for signal from comp..." << std::endl;
        }
        ParallelDescriptor::Bcast(&sidecarSignal, 1, 0, ParallelDescriptor::CommunicatorInter(whichSidecar));

        switch(sidecarSignal) {
          case NyxHaloFinderSignal:
	  {
#ifdef REEBER
            if(ParallelDescriptor::IOProcessor()) {
              std::cout << "Sidecars got the halo finder sidecarSignal!" << std::endl;
	    }
	    BoxArray bac;
            Geometry geom;
            int time_step, nComp(0), nGhost(0);

            // Receive the necessary data for doing analysis.
            ParallelDescriptor::Bcast(&nComp, 1, 0, ParallelDescriptor::CommunicatorInter(whichSidecar));
	    BoxArray::RecvBoxArray(bac, whichSidecar);
            MultiFab mf(bac, nComp, nGhost);

            MultiFab *mfSource = 0;
            MultiFab *mfDest = &mf;
            int srcComp(0), destComp(0);
            int srcNGhost(0), destNGhost(0);
            const MPI_Comm &commSrc = ParallelDescriptor::CommunicatorComp();
            const MPI_Comm &commDest = ParallelDescriptor::CommunicatorSidecar();
            const MPI_Comm &commInter = ParallelDescriptor::CommunicatorInter(whichSidecar);
            const MPI_Comm &commBoth = ParallelDescriptor::CommunicatorBoth(whichSidecar);
            bool isSrc(false);

            MultiFab::copyInter(mfSource, mfDest, srcComp, destComp, nComp,
                                srcNGhost, destNGhost,
                                commSrc, commDest, commInter, commBoth,
                                isSrc);

            Geometry::SendGeometryToSidecar(&geom, whichSidecar);
            ParallelDescriptor::Bcast(&time_step, 1, 0, ParallelDescriptor::CommunicatorInter(whichSidecar));

            // Here Reeber constructs the local-global merge trees and computes the
            // halo locations.
            runInSituAnalysis(mf, geom, time_step);

            if(ParallelDescriptor::IOProcessor()) {
              std::cout << "Sidecars completed halo finding analysis." << std::endl;
	    }
#else
      BoxLib::Abort("Nyx received halo finder signal but not compiled with Reeber");
#endif
	  }
          break;

          case GimletSignal:
	  {
#ifdef GIMLET
            if(ParallelDescriptor::IOProcessor()) {
              std::cout << "Sidecars got the halo finder GimletSignal!" << std::endl;
	    }
	    BoxArray bac;
            Geometry geom;
            int time_step;
            Real new_a, omega_m, omega_b, omega_l, comoving_h;

	    BoxArray::RecvBoxArray(bac, whichSidecar);

            MultiFab *mfSource = 0;
            MultiFab *mfDest = 0;
            int srcComp(0), destComp(0), nComp(1), nGhost(0);
            int srcNGhost(0), destNGhost(0);
            const MPI_Comm &commSrc = ParallelDescriptor::CommunicatorComp();
            const MPI_Comm &commDest = ParallelDescriptor::CommunicatorSidecar();
            const MPI_Comm &commInter = ParallelDescriptor::CommunicatorInter(whichSidecar);
            const MPI_Comm &commBoth = ParallelDescriptor::CommunicatorBoth(whichSidecar);
            bool isSrc(false);

	    // ---- we should probably combine all of these into one MultiFab
            MultiFab density(bac, nComp, nGhost);
            MultiFab temperature(bac, nComp, nGhost);
            MultiFab e_int(bac, nComp, nGhost);
            MultiFab dm_density(bac, nComp, nGhost);
            MultiFab xmom(bac, nComp, nGhost);
            MultiFab ymom(bac, nComp, nGhost);
            MultiFab zmom(bac, nComp, nGhost);

	    mfDest = &density;
            MultiFab::copyInter(mfSource, mfDest, srcComp, destComp, nComp,
                                srcNGhost, destNGhost, commSrc, commDest, commInter, commBoth, isSrc);

	    mfDest = &temperature;
            MultiFab::copyInter(mfSource, mfDest, srcComp, destComp, nComp,
                                srcNGhost, destNGhost, commSrc, commDest, commInter, commBoth, isSrc);

	    mfDest = &e_int;
            MultiFab::copyInter(mfSource, mfDest, srcComp, destComp, nComp,
                                srcNGhost, destNGhost, commSrc, commDest, commInter, commBoth, isSrc);

	    mfDest = &dm_density;
            MultiFab::copyInter(mfSource, mfDest, srcComp, destComp, nComp,
                                srcNGhost, destNGhost, commSrc, commDest, commInter, commBoth, isSrc);

	    mfDest = &xmom;
            MultiFab::copyInter(mfSource, mfDest, srcComp, destComp, nComp,
                                srcNGhost, destNGhost, commSrc, commDest, commInter, commBoth, isSrc);

	    mfDest = &ymom;
            MultiFab::copyInter(mfSource, mfDest, srcComp, destComp, nComp,
                                srcNGhost, destNGhost, commSrc, commDest, commInter, commBoth, isSrc);

	    mfDest = &zmom;
            MultiFab::copyInter(mfSource, mfDest, srcComp, destComp, nComp,
                                srcNGhost, destNGhost, commSrc, commDest, commInter, commBoth, isSrc);

            Geometry::SendGeometryToSidecar(&geom, whichSidecar);

            ParallelDescriptor::Bcast(&new_a, 1, 0, commInter);
            ParallelDescriptor::Bcast(&omega_m, 1, 0, commInter);
            omega_l = 1.0 - omega_m;
            ParallelDescriptor::Bcast(&omega_b, 1, 0, commInter);
            ParallelDescriptor::Bcast(&comoving_h, 1, 0, commInter);
            ParallelDescriptor::Bcast(&time_step, 1, 0, commInter);

            if(ParallelDescriptor::IOProcessor()) {
              std::cout << "===== Sidecars got everything ..." << std::endl;
            }

            Real time1 = ParallelDescriptor::second();
            do_analysis(omega_b, omega_m, omega_l, comoving_h, new_a, density, temperature,
                        e_int, dm_density, xmom, ymom, zmom, geom, time_step);
            Real dtime = ParallelDescriptor::second() - time1;
            ParallelDescriptor::ReduceRealMax(dtime, ParallelDescriptor::IOProcessorNumber());
            if(ParallelDescriptor::IOProcessor()) {
              std::cout << std::endl << "===== Time for Gimlet in-transit to post-process (sec): "
	                << dtime << " sec" << std::endl << std::flush;
            }
            ParallelDescriptor::Barrier();
#else
            BoxLib::Abort("Nyx received Gimlet signal but not compiled with Gimlet");
#endif
	  }
          break;

          case resizeSignal:
	  {
            if(ParallelDescriptor::IOProcessor()) {
              std::cout << "_in sidecars:  Sidecars received the resize sidecarSignal." << std::endl;
            }
	    finished = true;
	  }
          break;

          case quitSignal:
	  {
            if(ParallelDescriptor::IOProcessor()) {
              std::cout << "Sidecars received the quit sidecarSignal." << std::endl;
            }
            finished = true;
	  }
          break;

          default:
	  {
            if(ParallelDescriptor::IOProcessor()) {
              std::cout << "**** Sidecars received bad sidecarSignal = " << sidecarSignal << std::endl;
            }
	  }
          break;
        }

    }
    if(ParallelDescriptor::IOProcessor()) {
      if(sidecarSignal == resizeSignal) {
        std::cout << "===== Sidecars exiting for resize. =====" << std::endl;
      }
      if(sidecarSignal == quitSignal) {
        std::cout << "===== Sidecars quitting. =====" << std::endl;
      }
    }
    return sidecarSignal;
#endif
  }


  static void SidecarInit() {
#ifdef IN_SITU
    if(ParallelDescriptor::InSidecarGroup() && ParallelDescriptor::IOProcessor()) {
      std::cout << "Initializing Reeber on sidecars ... " << std::endl;
    }
    initInSituAnalysis();
#endif
  }
#endif
}




int
main (int argc, char* argv[])
{
    BoxLib::Initialize(argc, argv);


    // save the inputs file name for later
    if (argc > 1) {
      if (!strchr(argv[1], '=')) {
        inputs_name = argv[1];
      }
    }
    BL_PROFILE_REGION_START("main()");
    BL_PROFILE_VAR("main()", pmain);

#ifdef IN_SITU
      initInSituAnalysis();
#endif

    //
    // Don't start timing until all CPUs are ready to go.
    //
    ParallelDescriptor::Barrier("Starting main.");

    BL_COMM_PROFILE_NAMETAG("main TOP");

    const int MPI_IntraGroup_Broadcast_Rank = ParallelDescriptor::IOProcessor() ? MPI_ROOT : MPI_PROC_NULL;
    int nSidecarProcs(0), nSidecarProcsFromParmParse(-3);
    int prevSidecarProcs(0), minSidecarProcs(0), maxSidecarProcs(0);
    int sidecarSignal(NyxHaloFinderSignal);
    int resizeSidecars(false);  // ---- instead of bool for bcast
    Array<int> sidecarSizes;
    bool useRandomNSidecarProcs(false);

    // ---- these sizes work with fftw
    if(ParallelDescriptor::IOProcessor()) {
      sidecarSizes.push_back(128);
      sidecarSizes.push_back(256);
      sidecarSizes.push_back(320);
      sidecarSizes.push_back(512);
      sidecarSizes.push_back(640);
      sidecarSizes.push_back(704);
      sidecarSizes.push_back(768);
      sidecarSizes.push_back(832);
      sidecarSizes.push_back(896);
      sidecarSizes.push_back(960);
      sidecarSizes.push_back(1024);
    }

    Real dRunTime1 = ParallelDescriptor::second();

    std::cout << std::setprecision(10);

    int max_step;
    Real strt_time;
    Real stop_time;
    ParmParse pp;

    max_step  = -1;
    strt_time =  0.0;
    stop_time = -1.0;

    pp.query("max_step",  max_step);
    pp.query("strt_time", strt_time);
    pp.query("stop_time", stop_time);

    int how(-1);
    pp.query("how",how);
    pp.query("useRandomNSidecarProcs",useRandomNSidecarProcs);

#ifdef IN_TRANSIT
    pp.query("nSidecars", nSidecarProcsFromParmParse);
    pp.query("minSidecarProcs", minSidecarProcs);
    pp.query("maxSidecarProcs", maxSidecarProcs);
    if(ParallelDescriptor::IOProcessor()) {
      std::cout << "nSidecarProcs from parmparse = " << nSidecarProcsFromParmParse << std::endl;
    }
    resizeSidecars = !(prevSidecarProcs == nSidecarProcs);
    prevSidecarProcs = nSidecarProcs;
    if(nSidecarProcsFromParmParse >= 0) {
      if(nSidecarProcsFromParmParse >= ParallelDescriptor::NProcsAll()) {
        BoxLib::Abort("**** Error:  nSidecarProcsFromParmParse >= nProcs");
      }
      nSidecarProcs = nSidecarProcsFromParmParse;
    }
    nSidecarProcs = std::min(nSidecarProcs, maxSidecarProcs);
    nSidecarProcs = std::max(nSidecarProcs, minSidecarProcs);

#endif

    if (strt_time < 0.0)
    {
        BoxLib::Abort("MUST SPECIFY a non-negative strt_time");
    }

    if (max_step < 0 && stop_time < 0.0)
    {
        BoxLib::Abort("Exiting because neither max_step nor stop_time is non-negative.");
    }


    // This initialization is only for Reeber.
#ifdef IN_TRANSIT
    SidecarInit();
#endif

    Nyx::forceParticleRedist = true;

    Amr *amrptr = new Amr;
    amrptr->init(strt_time,stop_time);

#if BL_USE_MPI
    // ---- initialize nyx memory monitoring
    MemInfo *mInfo = MemInfo::GetInstance();
    mInfo->LogSummary("MemInit  ");
#endif

    // ---- set initial sidecar size
    ParallelDescriptor::Bcast(&nSidecarProcs, 1, 0, ParallelDescriptor::CommunicatorAll());
    if(ParallelDescriptor::IOProcessor()) {
      std::cout << "IIIIIIII new nSidecarProcs = " << nSidecarProcs << std::endl;
      std::cout << "IIIIIIII     minSidecarProcs = " << minSidecarProcs << std::endl;
      std::cout << "IIIIIIII     maxSidecarProcs = " << maxSidecarProcs << std::endl;
    }

    if(nSidecarProcs < prevSidecarProcs) {
      ResizeSidecars(nSidecarProcs);
      amrptr->AddProcsToComp(nSidecarProcs, prevSidecarProcs);
      amrptr->RedistributeGrids(how);
    } else if (nSidecarProcs > prevSidecarProcs) {
      if(ParallelDescriptor::InCompGroup()) {
        amrptr->AddProcsToSidecar(nSidecarProcs, prevSidecarProcs);
      }
      ResizeSidecars(nSidecarProcs);
    }

#ifdef BL_USE_MPI
    ParallelDescriptor::SetNProcsSidecars(nSidecarProcs);
#endif

    if(ParallelDescriptor::IOProcessor()) {
      std::cout << "************** sizeof(Amr)      = " << sizeof(Amr) << std::endl;
      std::cout << "************** sizeof(AmrLevel) = " << sizeof(AmrLevel) << std::endl;
    }

    bool finished(false);

    while ( ! finished) {

      Nyx::forceParticleRedist = true;

      if(ParallelDescriptor::InSidecarGroup()) {  // ------------------- start sidecars

        int returnCode = SidecarEventLoop();
        if(returnCode == quitSignal) {
          finished = true;
        }
        if(returnCode == resizeSignal) {
          resizeSidecars = true;
        } else {
          resizeSidecars = false;
        }

      } else {  // ----------------------------------------------------- start comp

        // If we set the regrid_on_restart flag and if we are *not* going to take
        // a time step then we want to go ahead and regrid here.
        //
        if (amrptr->RegridOnRestart()) {
          if (    (amrptr->levelSteps(0) >= max_step ) ||
                  ( (stop_time >= 0.0) &&
                    (amrptr->cumTime() >= stop_time)  )    )
          {
              // Regrid only!
              amrptr->RegridOnly(amrptr->cumTime());
          }
        }

        if (amrptr->okToContinue()
             && (amrptr->levelSteps(0) < max_step || max_step < 0)
             && (amrptr->cumTime() < stop_time || stop_time < 0.0))

        {
          amrptr->coarseTimeStep(stop_time);          // ---- Do a timestep.
        } else {
          finished = true;
          resizeSidecars = false;
        }


	if( ! finished) {    // ---- test resizing the sidecars
          prevSidecarProcs = nSidecarProcs;
	  if(ParallelDescriptor::IOProcessor()) {
	    if(useRandomNSidecarProcs) {
              nSidecarProcs = BoxLib::Random_int(ParallelDescriptor::NProcsAll()/2);
	    } else {
              nSidecarProcs = sidecarSizes[BoxLib::Random_int(sidecarSizes.size())];
	    }
	    // ---- fftw does not like these values
            if(nSidecarProcs == 12) {
              std::cout << "12121212:  skipping 12 sidecars." << std::endl;
              nSidecarProcs = 11;
            }
            if(nSidecarProcs == 14) {
              std::cout << "14141414:  skipping 14 sidecars." << std::endl;
              nSidecarProcs = 13;
            }
            if(nSidecarProcs == 15) {
              std::cout << "15151515:  skipping 15 sidecars." << std::endl;
              nSidecarProcs = 8;
            }
            nSidecarProcs = std::min(nSidecarProcs, maxSidecarProcs);
            nSidecarProcs = std::max(nSidecarProcs, minSidecarProcs);
	    if(useRandomNSidecarProcs) {
              std::cout << "Setting random size:  nSidecarProcs = " << nSidecarProcs << std::endl;
	    } else {
              std::cout << "Setting random fixed size:  nSidecarProcs = " << nSidecarProcs << std::endl;
	    }
	  }
          ParallelDescriptor::Bcast(&nSidecarProcs, 1, 0);
          if(prevSidecarProcs != nSidecarProcs) {
            resizeSidecars = true;
          } else {
            resizeSidecars = false;
          }
	}

        if((finished || resizeSidecars) && nSidecarProcs > 0 && prevSidecarProcs > 0) {
	  // ---- stop the sidecars
          int sidecarSignal(-1);
          if(finished) {
            sidecarSignal = quitSignal;
	  } else if(resizeSidecars) {
            sidecarSignal = resizeSignal;
	  }
	  int whichSidecar(0);
          ParallelDescriptor::Bcast(&sidecarSignal, 1, MPI_IntraGroup_Broadcast_Rank,
                                    ParallelDescriptor::CommunicatorInter(whichSidecar));
        }

      }  // ---------------- end start comp



#ifdef IN_TRANSIT
      if(resizeSidecars) {    // ---- both comp and sidecars are here
        ParallelDescriptor::Bcast(&prevSidecarProcs, 1, 0, ParallelDescriptor::CommunicatorAll());
        ParallelDescriptor::Bcast(&nSidecarProcs, 1, 0, ParallelDescriptor::CommunicatorAll());
        if(ParallelDescriptor::InCompGroup()) {
          if(ParallelDescriptor::IOProcessor()) {
            std::cout << "NNNNNNNN new nSidecarProcs    = " << nSidecarProcs    << std::endl;
            std::cout << "NNNNNNNN     prevSidecarProcs = " << prevSidecarProcs << std::endl;
          }
	}
        Nyx::forceParticleRedist = true;

        if(nSidecarProcs < prevSidecarProcs) {
          ResizeSidecars(nSidecarProcs);
        }

        if(nSidecarProcs > prevSidecarProcs) {
          if(ParallelDescriptor::InCompGroup()) {
            amrptr->AddProcsToSidecar(nSidecarProcs, prevSidecarProcs);
          } else {
	    DistributionMapping::DeleteCache();
	  }
        }

        if(nSidecarProcs < prevSidecarProcs) {

          amrptr->AddProcsToComp(nSidecarProcs, prevSidecarProcs);
          amrptr->RedistributeGrids(how);
        }

        if(nSidecarProcs > prevSidecarProcs) {
          ResizeSidecars(nSidecarProcs);
        }
        if(ParallelDescriptor::IOProcessor()) {
          std::cout << "@@@@@@@@ after resize sidecars:  restarting event loop." << std::endl;
        }
      }
#endif


    }  // ---- end while( ! finished)



    if(ParallelDescriptor::InCompGroup()) {
      // Write final checkpoint and plotfile
      if (amrptr->stepOfLastCheckPoint() < amrptr->levelSteps(0)) {
        amrptr->checkPoint();
      }
      if (amrptr->stepOfLastPlotFile() < amrptr->levelSteps(0)) {
        amrptr->writePlotFile();
      }
    }

#ifdef IN_TRANSIT
    if(nSidecarProcs > 0) {    // ---- stop the sidecars
      sidecarSignal = quitSignal;
      int whichSidecar(0);
      ParallelDescriptor::Bcast(&sidecarSignal, 1, MPI_IntraGroup_Broadcast_Rank,
                                ParallelDescriptor::CommunicatorInter(whichSidecar));
    }
#endif

#ifdef BL_USE_MPI
    ParallelDescriptor::SetNProcsSidecars(0);
#endif

    delete amrptr;


    //
    // This MUST follow the above delete as ~Amr() may dump files to disk.
    //
    const int IOProc = ParallelDescriptor::IOProcessorNumber();

    Real dRunTime2 = ParallelDescriptor::second() - dRunTime1;

    ParallelDescriptor::ReduceRealMax(dRunTime2, IOProc);

    if (ParallelDescriptor::IOProcessor())
    {
        std::cout << "Run time = " << dRunTime2 << std::endl;
    }

    BL_PROFILE_VAR_STOP(pmain);
    BL_PROFILE_REGION_STOP("main()");
    BL_PROFILE_SET_RUN_TIME(dRunTime2);

    BoxLib::Finalize();

    return 0;
}
