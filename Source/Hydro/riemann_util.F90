module riemann_util_module

  use amrex_fort_module, only : rt => amrex_real
  use amrex_constants_module, only : ZERO, ONE, HALF
  implicit none

contains

  AMREX_CUDA_FORT_DEVICE subroutine analriem_1cell(gamma,pl,rl,ul,pr,rr,ur,smallp,pstar,ustar)

      use amrex_fort_module, only : rt => amrex_real
      implicit none

      real(rt), intent(in ) :: pl,rl,ul,pr,rr,ur
      real(rt), intent(in ) :: gamma, smallp
      real(rt), intent(out) :: pstar,ustar

      ! Local variables
      real(rt) :: pstnm1,ustarp,ustarm
      real(rt) :: wl,wr,wlsq,wrsq
      real(rt) :: cleft,cright
      real(rt) :: dpditer,zp,zm,denom
      real(rt) :: ustnm1,ustnp1
      integer          :: iter

      real(rt), parameter :: weakwv = 1.d-3
      real(rt), parameter :: small  = 1.d-6

      integer :: i

      wl = sqrt(gamma*pl*rl)
      wr = sqrt(gamma*pr*rr)

      cleft  = wl/rl
      cright = wr/rr

      pstar=(wl*pr+wr*pl-wr*wl*(ur-ul))/(wl+wr)

      pstar=max(pstar,smallp)
      pstnm1 = pstar

      wlsq = (.5d0*(gamma-1.d0)*(pstar+pl)+pstar) * rl
      wrsq = (.5d0*(gamma-1.d0)*(pstar+pr)+pstar) * rr

      wl = sqrt(wlsq)
      wr = sqrt(wrsq)

      ustarp = ul - (pstar-pl)/wl
      ustarm = ur + (pstar-pr)/wr

      pstar = (wl*pr+wr*pl-wr*wl*(ur-ul))/(wl+wr)

      pstar=max(pstar,smallp)

      do iter = 1,3

        wlsq = (.5d0*(gamma-1.d0)*(pstar+pl)+pstar) * rl
        wrsq = (.5d0*(gamma-1.d0)*(pstar+pr)+pstar) * rr

        wl = 1.d0/sqrt(wlsq)
        wr = 1.d0/sqrt(wrsq)

        ustnm1 = ustarm
        ustnp1 = ustarp

        ustarm = ur - (pr-pstar)*wr
        ustarp = ul + (pl-pstar)*wl

        dpditer = abs(pstnm1-pstar)
        zp      = abs(ustarp-ustnp1)

        if (zp-weakwv*cleft .lt. 0.0d0 ) then
            zp = dpditer*wl
         endif

        zm=abs(ustarm-ustnm1)

        if (zm-weakwv*cright .lt. 0.0d0 ) then
           zm = dpditer*wr
        endif

        denom  = dpditer/max(zp+zm,small*(cleft+cright))
        pstnm1 = pstar

        pstar = pstar - denom*(ustarm-ustarp)

        pstar = max(pstar,smallp)

        ustar = 0.5d0*(ustarm+ustarp)

     end do

    end subroutine analriem_1cell
  !> @brief compute the lagrangian wave speeds -- this is the approximate
  !! version for the Colella & Glaz algorithm
  !!
  !! @param[in] p real(rt)
  !! @param[in] v real(rt)
  !! @param[in] gam real(rt)
  !! @param[in] gdot real(rt)
  !! @param[in] pstar real(rt)
  !! @param[in] csq real(rt)
  !! @param[in] gmin real(rt)
  !! @param[in] gmax real(rt)
  !! @param[out] wsq real(rt)
  !! @param[out] gstar real(rt)
  !!
  pure subroutine wsqge(p,v,gam,gdot,gstar,pstar,wsq,csq,gmin,gmax)


    real(rt)        , intent(in) :: p,v,gam,gdot,pstar,csq,gmin,gmax
    real(rt)        , intent(out) :: wsq, gstar

    real(rt)        , parameter :: smlp1 = 1.e-10_rt
    real(rt)        , parameter :: small = 1.e-7_rt

    real(rt)         :: alpha, beta

    !$gpu

    ! First predict a value of game across the shock

    ! CG Eq. 31
    gstar = (pstar-p)*gdot/(pstar+p) + gam
    gstar = max(gmin, min(gmax, gstar))

    ! Now use that predicted value of game with the R-H jump conditions
    ! to compute the wave speed.

    ! this is CG Eq. 34
    alpha = pstar - (gstar-ONE)*p/(gam-ONE)
    if (alpha == ZERO) alpha = smlp1*(pstar + p)

    beta = pstar + HALF*(gstar-ONE)*(pstar+p)

    wsq = (pstar-p)*beta/(v*alpha)

    if (abs(pstar - p) < smlp1*(pstar + p)) then
       wsq = csq
    endif
    wsq = max(wsq, (HALF*(gam-ONE)/gam)*csq)

    return
  end subroutine wsqge



  !> @brief we want to zero
  !! f(p*) = u*_l(p*) - u*_r(p*)
  !! we'll do bisection
  !!
  !! this version is for the approximate Colella & Glaz
  !! version
  !!
  !! @param[inout] pstar_lo real(rt)
  !! @param[inout] pstar_hi real(rt)
  !! @param[in] ul real(rt)
  !! @param[in] pl real(rt)
  !! @param[in] taul real(rt)
  !! @param[in] gamel real(rt)
  !! @param[in] clsql real(rt)
  !! @param[in] ur real(rt)
  !! @param[in] pr real(rt)
  !! @param[in] taur real(rt)
  !! @param[in] gamer real(rt)
  !! @param[in] clsqr real(rt)
  !! @param[in] gdot real(rt)
  !! @param[in] gmin real(rt)
  !! @param[in] gmax real(rt)
  !! @param[out] pstar real(rt)
  !! @param[out] gamstar real(rt)
  !! @param[out] converged logical
  !! @param[out] pstar_hist_extra real(rt)
  !!
  pure subroutine pstar_bisection(pstar_lo, pstar_hi, &
       ul, pl, taul, gamel, clsql, &
       ur, pr, taur, gamer, clsqr, &
       gdot, gmin, gmax, &
       pstar, gamstar, converged, pstar_hist_extra)

    use meth_params_module, only : cg_maxiter, cg_tol

    real(rt)        , intent(inout) :: pstar_lo, pstar_hi
    real(rt)        , intent(in) :: ul, pl, taul, gamel, clsql
    real(rt)        , intent(in) :: ur, pr, taur, gamer, clsqr
    real(rt)        , intent(in) :: gdot, gmin, gmax
    real(rt)        , intent(out) :: pstar, gamstar
    logical, intent(out) :: converged
    real(rt)        , intent(out) :: pstar_hist_extra(:)

    real(rt)         :: pstar_c, ustar_l, ustar_r, f_lo, f_hi, f_c
    real(rt)         :: wl, wr, wlsq, wrsq

    integer :: iter


    ! lo bounds
    call wsqge(pl, taul, gamel, gdot,  &
         gamstar, pstar_lo, wlsq, clsql, gmin, gmax)

    call wsqge(pr, taur, gamer, gdot,  &
         gamstar, pstar_lo, wrsq, clsqr, gmin, gmax)

    wl = ONE / sqrt(wlsq)
    wr = ONE / sqrt(wrsq)

    ustar_l = ul - (pstar_lo - pstar)*wl
    ustar_r = ur + (pstar_lo - pstar)*wr

    f_lo = ustar_l - ustar_r


    ! hi bounds
    call wsqge(pl, taul, gamel, gdot,  &
         gamstar, pstar_hi, wlsq, clsql, gmin, gmax)

    call wsqge(pr, taur, gamer, gdot,  &
         gamstar, pstar_hi, wrsq, clsqr, gmin, gmax)

    wl = ONE / sqrt(wlsq)
    wr = ONE / sqrt(wrsq)

    ustar_l = ul - (pstar_hi - pstar)*wl
    ustar_r = ur + (pstar_hi - pstar)*wr

    f_hi = ustar_l - ustar_r

    ! bisection
    iter = 1
    do while (iter <= cg_maxiter)

       pstar_c = HALF * (pstar_lo + pstar_hi)

       pstar_hist_extra(iter) = pstar_c

       call wsqge(pl, taul, gamel, gdot,  &
            gamstar, pstar_c, wlsq, clsql, gmin, gmax)

       call wsqge(pr, taur, gamer, gdot,  &
            gamstar, pstar_c, wrsq, clsqr, gmin, gmax)

       wl = ONE / sqrt(wlsq)
       wr = ONE / sqrt(wrsq)

       ustar_l = ul - (pstar_c - pl)*wl
       ustar_r = ur - (pstar_c - pr)*wr

       f_c = ustar_l - ustar_r

       if ( HALF * abs(pstar_lo - pstar_hi) < cg_tol * pstar_c ) then
          converged = .true.
          exit
       endif

       if (f_lo * f_c < ZERO) then
          ! root is in the left half
          pstar_hi = pstar_c
          f_hi = f_c
       else
          pstar_lo = pstar_c
          f_lo = f_c
       endif
    enddo

    pstar = pstar_c

  end subroutine pstar_bisection



  !>
  !! @param[in] ql real(rt)
  !! @param[inout] f real(rt)
  !! @param[in] idir integer
  !!
  subroutine HLL(ql, qr, cl, cr, idir, f)

    use meth_params_module, only : QVAR, NVAR, QRHO, QU, QV, QW, QPRES, QREINT, &
         URHO, UMX, UMY, UMZ, UEDEN, UEINT, &
         npassive, upass_map, qpass_map

    use amrex_fort_module, only : rt => amrex_real
    real(rt), intent(in) :: ql(QVAR), qr(QVAR), cl, cr
    real(rt), intent(inout) :: f(NVAR)
    integer, intent(in) :: idir

    integer :: ivel, ivelt, iveltt, imom, imomt, imomtt
    real(rt) :: a1, a4, bd, bl, bm, bp, br
    real(rt) :: cavg, uavg
    real(rt) :: fl_tmp, fr_tmp
    real(rt) :: rhod, rhoEl, rhoEr, rhol_sqrt, rhor_sqrt
    integer :: n, nqs

    integer :: ipassive

    real(rt)        , parameter :: small = 1.e-10_rt

    !$gpu

    select case (idir)
    case (1)
       ivel = QU
       ivelt = QV
       iveltt = QW

       imom = UMX
       imomt = UMY
       imomtt = UMZ

    case (2)
       ivel = QV
       ivelt = QU
       iveltt = QW

       imom = UMY
       imomt = UMX
       imomtt = UMZ

    case (3)
       ivel = QW
       ivelt = QU
       iveltt = QV

       imom = UMZ
       imomt = UMX
       imomtt = UMY

    end select

    rhol_sqrt = sqrt(ql(QRHO))
    rhor_sqrt = sqrt(qr(QRHO))

    rhod = ONE/(rhol_sqrt + rhor_sqrt)



    ! compute the average sound speed. This uses an approximation from
    ! E88, eq. 5.6, 5.7 that assumes gamma falls between 1
    ! and 5/3
    cavg = sqrt( (rhol_sqrt*cl**2 + rhor_sqrt*cr**2)*rhod + &
         HALF*rhol_sqrt*rhor_sqrt*rhod**2*(qr(ivel) - ql(ivel))**2 )


    ! Roe eigenvalues (E91, eq. 5.3b)
    uavg = (rhol_sqrt*ql(ivel) + rhor_sqrt*qr(ivel))*rhod

    a1 = uavg - cavg
    a4 = uavg + cavg


    ! signal speeds (E91, eq. 4.5)
    bl = min(a1, ql(ivel) - cl)
    br = max(a4, qr(ivel) + cr)

    bm = min(ZERO, bl)
    bp = max(ZERO, br)

    bd = bp - bm

    if (abs(bd) < small*max(abs(bm),abs(bp))) return

    bd = ONE/bd


    ! compute the fluxes according to E91, eq. 4.4b -- note that the
    ! min/max above picks the correct flux if we are not in the star
    ! region

    ! density flux
    fl_tmp = ql(QRHO)*ql(ivel)
    fr_tmp = qr(QRHO)*qr(ivel)

    f(URHO) = (bp*fl_tmp - bm*fr_tmp)*bd + bp*bm*bd*(qr(QRHO) - ql(QRHO))


    ! normal momentum flux.  Note for 1-d and 2-d non cartesian
    ! r-coordinate, we leave off the pressure term and handle that
    ! separately in the update, to accommodate different geometries
    fl_tmp = ql(QRHO)*ql(ivel)**2
    fr_tmp = qr(QRHO)*qr(ivel)**2

    f(imom) = (bp*fl_tmp - bm*fr_tmp)*bd + bp*bm*bd*(qr(QRHO)*qr(ivel) - ql(QRHO)*ql(ivel))


    ! transverse momentum flux
    fl_tmp = ql(QRHO)*ql(ivel)*ql(ivelt)
    fr_tmp = qr(QRHO)*qr(ivel)*qr(ivelt)

    f(imomt) = (bp*fl_tmp - bm*fr_tmp)*bd + bp*bm*bd*(qr(QRHO)*qr(ivelt) - ql(QRHO)*ql(ivelt))


    fl_tmp = ql(QRHO)*ql(ivel)*ql(iveltt)
    fr_tmp = qr(QRHO)*qr(ivel)*qr(iveltt)

    f(imomtt) = (bp*fl_tmp - bm*fr_tmp)*bd + bp*bm*bd*(qr(QRHO)*qr(iveltt) - ql(QRHO)*ql(iveltt))


    ! total energy flux
    rhoEl = ql(QREINT) + HALF*ql(QRHO)*(ql(ivel)**2 + ql(ivelt)**2 + ql(iveltt)**2)
    fl_tmp = ql(ivel)*(rhoEl + ql(QPRES))

    rhoEr = qr(QREINT) + HALF*qr(QRHO)*(qr(ivel)**2 + qr(ivelt)**2 + qr(iveltt)**2)
    fr_tmp = qr(ivel)*(rhoEr + qr(QPRES))

    f(UEDEN) = (bp*fl_tmp - bm*fr_tmp)*bd + bp*bm*bd*(rhoEr - rhoEl)


    ! eint flux
    fl_tmp = ql(QREINT)*ql(ivel)
    fr_tmp = qr(QREINT)*qr(ivel)

    f(UEINT) = (bp*fl_tmp - bm*fr_tmp)*bd + bp*bm*bd*(qr(QREINT) - ql(QREINT))


    ! passively-advected scalar fluxes
    do ipassive = 1, npassive
       n  = upass_map(ipassive)
       nqs = qpass_map(ipassive)

       fl_tmp = ql(QRHO)*ql(nqs)*ql(ivel)
       fr_tmp = qr(QRHO)*qr(nqs)*qr(ivel)

       f(n) = (bp*fl_tmp - bm*fr_tmp)*bd + bp*bm*bd*(qr(QRHO)*qr(nqs) - ql(QRHO)*ql(nqs))
    enddo

  end subroutine HLL



  !>
  !! @param[in] q real(rt)
  !! @param[out] U real(rt)
  !!
  pure subroutine cons_state(q, U)

    use meth_params_module, only: QVAR, QRHO, QU, QV, QW, QREINT, &
         NVAR, URHO, UMX, UMY, UMZ, UEDEN, UEINT, UTEMP, &
#ifdef SHOCK_VAR
         USHK, &
#endif
         npassive, upass_map, qpass_map

    real(rt)        , intent(in)  :: q(QVAR)
    real(rt)        , intent(out) :: U(NVAR)

    integer :: ipassive, n, nqs

    !$gpu

    U(URHO) = q(QRHO)

    ! since we advect all 3 velocity components regardless of dimension, this
    ! will be general
    U(UMX)  = q(QRHO)*q(QU)
    U(UMY)  = q(QRHO)*q(QV)
    U(UMZ)  = q(QRHO)*q(QW)

    U(UEDEN) = q(QREINT) + HALF*q(QRHO)*(q(QU)**2 + q(QV)**2 + q(QW)**2)
    U(UEINT) = q(QREINT)

    ! we don't care about T here, but initialize it to make NaN
    ! checking happy
    U(UTEMP) = ZERO

#ifdef SHOCK_VAR
    U(USHK) = ZERO
#endif

    do ipassive = 1, npassive
       n  = upass_map(ipassive)
       nqs = qpass_map(ipassive)
       U(n) = q(QRHO)*q(nqs)
    enddo

  end subroutine cons_state



  !>
  !! @param[in] idir integer
  !! @param[in] S_k real(rt)
  !! @param[in] S_c real(rt)
  !! @param[in] q real(rt)
  !! @param[out] U real(rt)
  !!
  pure subroutine HLLC_state(idir, S_k, S_c, q, U)

    use meth_params_module, only: QVAR, QRHO, QU, QV, QW, QREINT, QPRES, &
         NVAR, URHO, UMX, UMY, UMZ, UEDEN, UEINT, UTEMP, &
#ifdef SHOCK_VAR
         USHK, &
#endif
         npassive, upass_map, qpass_map

    integer, intent(in) :: idir
    real(rt), intent(in)  :: S_k, S_c
    real(rt), intent(in)  :: q(QVAR)
    real(rt), intent(out) :: U(NVAR)

    real(rt)         :: hllc_factor, u_k
    integer :: ipassive, n, nqs

    !$gpu

    if (idir == 1) then
       u_k = q(QU)
    elseif (idir == 2) then
       u_k = q(QV)
    elseif (idir == 3) then
       u_k = q(QW)
    endif

    hllc_factor = q(QRHO)*(S_k - u_k)/(S_k - S_c)
    U(URHO) = hllc_factor
    if (idir == 1) then
       U(UMX)  = hllc_factor*S_c
       U(UMY)  = hllc_factor*q(QV)
       U(UMZ)  = hllc_factor*q(QW)
    elseif (idir == 2) then
       U(UMX)  = hllc_factor*q(QU)
       U(UMY)  = hllc_factor*S_c
       U(UMZ)  = hllc_factor*q(QW)
    elseif (idir == 3) then
       U(UMX)  = hllc_factor*q(QU)
       U(UMY)  = hllc_factor*q(QV)
       U(UMZ)  = hllc_factor*S_c
    endif

    U(UEDEN) = hllc_factor*(q(QREINT)/q(QRHO) + &
         HALF*(q(QU)**2 + q(QV)**2 + q(QW)**2) + &
         (S_c - u_k)*(S_c + q(QPRES)/(q(QRHO)*(S_k - u_k))))
    U(UEINT) = hllc_factor*q(QREINT)/q(QRHO)

    U(UTEMP) = ZERO  ! we don't evolve T

#ifdef SHOCK_VAR
    U(USHK) = ZERO
#endif

    do ipassive = 1, npassive
       n  = upass_map(ipassive)
       nqs = qpass_map(ipassive)
       U(n) = hllc_factor*q(nqs)
    enddo

  end subroutine HLLC_state

  !> @brief given a primitive state, compute the flux in direction idir
  !!
  AMREX_CUDA_FORT_DEVICE subroutine compute_flux_q(lo, hi, &
                            qint, q_lo, q_hi, &
                            F, F_lo, F_hi, &
#ifdef RADIATION
                            lambda, l_lo, l_hi, &
                            rF, rF_lo, rF_hi, &
#endif
                            idir, enforce_eos)

    use meth_params_module, only : QVAR, NVAR, NQAUX, &
                                   URHO, UMX, UMY, UMZ, &
                                   UEDEN, UEINT, UTEMP, &
#ifdef SHOCK_VAR
                                   USHK, &
#endif
                                   QRHO, QU, QV, QW, &
                                   QPRES, QGAME, QREINT, &
                                   QC, QGAMC, QFS, &
#ifdef HYBRID_MOMENTUM
                                   NGDNV, GDPRES, GDGAME, &
                                   GDRHO, GDU, GDV, GDW, &
#endif
#ifdef RADIATION
                                   QRAD, fspace_type, &
                                   GDERADS, GDLAMS, &
#endif
                                   npassive, upass_map, qpass_map
#ifdef RADIATION
    use fluxlimiter_module, only : Edd_factor
    use rad_params_module, only : ngroups
#endif
#ifdef HYBRID_MOMENTUM
    use hybrid_advection_module, only : compute_hybrid_flux
#endif

    integer, intent(in) :: idir
    integer, intent(in) :: q_lo(3), q_hi(3)
    integer, intent(in) :: F_lo(3), F_hi(3)
#ifdef RADIATION
    integer, intent(in) :: l_lo(3), l_hi(3)
    integer, intent(in) :: rF_lo(3), rF_hi(3)
#endif

    real(rt), intent(in) :: qint(q_lo(1):q_hi(1), q_lo(2):q_hi(2), q_lo(3):q_hi(3), QVAR)
    real(rt), intent(out) :: F(F_lo(1):F_hi(1), F_lo(2):F_hi(2), F_lo(3):F_hi(3), NVAR)
#ifdef RADIATION
    real(rt), intent(in) :: lambda(l_lo(1):l_hi(1), l_lo(2):l_hi(2), l_lo(3):l_hi(3), 0:ngroups-1)
    real(rt), intent(out) :: rF(rF_lo(1):rF_hi(1), rF_lo(2):rF_hi(2), rF_lo(3):rF_hi(3), 0:ngroups-1)
#endif
    logical, intent(in), optional :: enforce_eos
    integer, intent(in) :: lo(3), hi(3)

    integer :: iu, iv1, iv2, im1, im2, im3
    integer :: g, n, ipassive, nqp
    real(rt) :: u_adv, rhoetot, rhoeint
    real(rt) :: eddf, f1
    integer :: i, j, k

#ifdef HYBRID_MOMENTUM
    real(rt) :: F_zone(NVAR), qgdnv_zone(NGDNV)
#endif

    logical :: do_eos

    !$gpu

    if (present(enforce_eos)) then
       do_eos = enforce_eos
    else
       do_eos = .false.
    endif


    if (idir == 1) then
       iu = QU
       iv1 = QV
       iv2 = QW
       im1 = UMX
       im2 = UMY
       im3 = UMZ
    else if (idir == 2) then
       iu = QV
       iv1 = QU
       iv2 = QW
       im1 = UMY
       im2 = UMX
       im3 = UMZ
    else
       iu = QW
       iv1 = QU
       iv2 = QV
       im1 = UMZ
       im2 = UMX
       im3 = UMY
    end if
    
    do k = lo(3), hi(3)
       do j = lo(2), hi(2)
          do i = lo(1), hi(1)

             u_adv = qint(i,j,k,iu)

             ! if we are enforcing the EOS, then take rho, p, and X, and
             ! compute rhoe
             rhoeint = qint(i,j,k,QREINT)

             ! Compute fluxes, order as conserved state (not q)
             F(i,j,k,URHO) = qint(i,j,k,QRHO)*u_adv

             F(i,j,k,im1) = F(i,j,k,URHO)*qint(i,j,k,iu)
             F(i,j,k,im1) = F(i,j,k,im1) + qint(i,j,k,QPRES)
             F(i,j,k,im2) = F(i,j,k,URHO)*qint(i,j,k,iv1)
             F(i,j,k,im3) = F(i,j,k,URHO)*qint(i,j,k,iv2)

             rhoetot = rhoeint + &
                  HALF*qint(i,j,k,QRHO)*(qint(i,j,k,iu)**2 + &
                  qint(i,j,k,iv1)**2 + &
                  qint(i,j,k,iv2)**2)

             F(i,j,k,UEDEN) = u_adv*(rhoetot + qint(i,j,k,QPRES))
             F(i,j,k,UEINT) = u_adv*rhoeint

#ifdef SHOCK_VAR
             F(i,j,k,USHK) = ZERO
#endif

#ifdef RADIATION
             if (fspace_type == 1) then
                do g=0,ngroups-1
                   eddf = Edd_factor(lambda(i,j,k,g))
                   f1 = 0.5e0_rt*(1.e0_rt-eddf)
                   rF(i,j,k,g) = (1.e0_rt + f1) * qint(i,j,k,QRAD+g) * u_adv
                end do
             else ! type 2
                do g=0,ngroups-1
                   rF(i,j,k,g) = qint(i,j,k,QRAD+g) * u_adv
                end do
             end if
#endif

             ! passively advected quantities
             do ipassive = 1, npassive
                n  = upass_map(ipassive)
                nqp = qpass_map(ipassive)

                F(i,j,k,n) = F(i,j,k,URHO)*qint(i,j,k,nqp)
             end do

#ifdef HYBRID_MOMENTUM

             ! the hybrid routine uses the Godunov indices, not the full NQ state
             qgdnv_zone(GDRHO) = qint(i,j,k,QRHO)
             qgdnv_zone(GDU) = qint(i,j,k,QU)
             qgdnv_zone(GDV) = qint(i,j,k,QV)
             qgdnv_zone(GDW) = qint(i,j,k,QW)
             qgdnv_zone(GDPRES) = qint(i,j,k,QPRES)
             qgdnv_zone(GDGAME) = qint(i,j,k,QGAME)
#ifdef RADIATION
             qgdnv_zone(GDLAMS:GDLAMS-1+ngroups) = lambda(i,j,k,:)
             qgdnv_zone(GDERADS:GDERADS-1+ngroups) = qint(i,j,k,QRAD:QRAD-1+ngroups)
#endif

             F_zone(:) = F(i,j,k,:)
             call compute_hybrid_flux(qgdnv_zone, F_zone, idir, [i, j, k])
             F(i,j,k,:) = F_zone(:)
#endif
          end do
       end do
    end do

  end subroutine compute_flux_q


  !> @brief this copies the full interface state (NQ -- one for each primitive
  !! variable) over to a smaller subset of size NGDNV for use later in the
  !! hydro advancement.
  !!
  !! @param[in] lo integer
  !! @param[in] hi integer
  !! @param[in] qi_lo integer
  !! @param[in] qi_hi integer
  !! @param[in] qg_lo integer
  !! @param[in] qg_hi integer
  !! @param[in] qint real(rt)
  !! @param[out] qgdnv real(rt)
  !!

    AMREX_CUDA_FORT_DEVICE subroutine ca_store_godunov_state(lo, hi, &
                                    qint, qi_lo, qi_hi, &
#ifdef RADIATION
                                    lambda, l_lo, l_hi, &
#endif
                                    qgdnv, qg_lo, qg_hi) bind(C, name="ca_store_godunov_state")

    use meth_params_module, only : QVAR, NVAR, NQAUX, &
                                   URHO, &
                                   QRHO, QU, QV, QW, &
                                   QPRES, QGAME, &
                                   NGDNV, GDRHO, GDPRES, GDGAME, &
#ifdef RADIATION
                                   QRAD, GDERADS, GDLAMS, &
#endif
                                   GDRHO, GDU, GDV, GDW, gamma_minus_1

#ifdef RADIATION
    use rad_params_module, only : ngroups
#endif

    integer, intent(in) :: lo(3), hi(3)
    integer, intent(in) :: qi_lo(3), qi_hi(3)
    integer, intent(in) :: qg_lo(3), qg_hi(3)
    real(rt), intent(in) :: qint(qi_lo(1):qi_hi(1), qi_lo(2):qi_hi(2), qi_lo(3):qi_hi(3), QVAR)
#ifdef RADIATION
    integer, intent(in) :: l_lo(3), l_hi(3)
    real(rt), intent(in) :: lambda(l_lo(1):l_hi(1), l_lo(2):l_hi(2), l_lo(3):l_hi(3), 0:ngroups-1)
#endif
    real(rt), intent(inout) :: qgdnv(qg_lo(1):qg_hi(1), qg_lo(2):qg_hi(2), qg_lo(3):qg_hi(3), NGDNV)

    integer :: i, j, k

    !$gpu

    do k = lo(3), hi(3)
       do j = lo(2), hi(2)
          do i = lo(1), hi(1)

             ! the hybrid routine uses the Godunov indices, not the full NQ state
             qgdnv(i,j,k,GDRHO) = qint(i,j,k,QRHO)
             qgdnv(i,j,k,GDU) = qint(i,j,k,QU)
             qgdnv(i,j,k,GDV) = qint(i,j,k,QV)
             qgdnv(i,j,k,GDW) = qint(i,j,k,QW)
             qgdnv(i,j,k,GDPRES) = qint(i,j,k,QPRES)
             qgdnv(i,j,k,GDGAME) = (gamma_minus_1+ONE)
#ifdef RADIATION
             qgdnv(i,j,k,GDLAMS:GDLAMS-1+ngroups) = lambda(i,j,k,:)
             qgdnv(i,j,k,GDERADS:GDERADS-1+ngroups) = qint(i,j,k,QRAD:QRAD-1+ngroups)
#endif
          end do
       end do
    end do

  end subroutine ca_store_godunov_state


  !> @brief given a conserved state, compute the flux in direction idir
  !!
  !! @param[in] idir integer
  !! @param[in] bnd_fac integer
  !! @param[in] U real(rt)
  !! @param[in] p real(rt)
  !! @param[out] F real(rt)
  !!
  pure subroutine compute_flux(idir, bnd_fac, U, p, F)

    use meth_params_module, only: NVAR, URHO, UMX, UMY, UMZ, UEDEN, UEINT, UTEMP, &
#ifdef SHOCK_VAR
         USHK, &
#endif
         npassive, upass_map

    integer, intent(in) :: idir, bnd_fac
    real(rt)        , intent(in) :: U(NVAR)
    real(rt)        , intent(in) :: p
    real(rt)        , intent(out) :: F(NVAR)

    integer :: ipassive, n
    real(rt)         :: u_flx

    !$gpu

    if (idir == 1) then
       u_flx = U(UMX)/U(URHO)
    elseif (idir == 2) then
       u_flx = U(UMY)/U(URHO)
    elseif (idir == 3) then
       u_flx = U(UMZ)/U(URHO)
    endif

    if (bnd_fac == 0) then
       u_flx = ZERO
    endif

    F(URHO) = U(URHO)*u_flx

    F(UMX) = U(UMX)*u_flx
    F(UMY) = U(UMY)*u_flx
    F(UMZ) = U(UMZ)*u_flx

    F(UMX-1+idir) = F(UMX-1+idir) + p
    
    F(UEINT) = U(UEINT)*u_flx
    F(UEDEN) = (U(UEDEN) + p)*u_flx

    F(UTEMP) = ZERO

#ifdef SHOCK_VAR
    F(USHK) = ZERO
#endif

    do ipassive = 1, npassive
       n = upass_map(ipassive)
       F(n) = U(n)*u_flx
    enddo

  end subroutine compute_flux

end module riemann_util_module
