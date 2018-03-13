subroutine integrate_state_vode(lo, hi, &
                                state   , s_l1, s_l2, s_l3, s_h1, s_h2, s_h3, &
                                diag_eos, d_l1, d_l2, d_l3, d_h1, d_h2, d_h3, &
                                src, src_l1, src_l2, src_l3, src_h1, src_h2, src_h3, &
                                a, half_dt, min_iter, max_iter, s_comp)
!
!   Calculates the sources to be added later on.
!
!   Parameters
!   ----------
!   lo : double array (3)
!       The low corner of the current box.
!   hi : double array (3)
!       The high corner of the current box.
!   state_* : double arrays
!       The state vars
!   diag_eos_* : double arrays
!       Temp and Ne
!   src_* : doubles arrays
!       The source terms to be added to state (iterative approx.)
!   double array (3)
!       The low corner of the entire domain
!   a : double
!       The current a
!   half_dt : double
!       time step size, in Mpc km^-1 s ~ 10^12 yr.
!
!   Returns
!   -------
!   state : double array (dims) @todo
!       The state vars
!
    use amrex_fort_module, only : rt => amrex_real
    use meth_params_module, only : NVAR, URHO, UEDEN, UEINT, UMX, &
                                   NDIAG, TEMP_COMP, NE_COMP, ZHI_COMP, &
                                   SFNR_COMP,  SSNR_COMP, DIAG1_COMP, DIAG2_COMP, STRANG_COMP, gamma_minus_1
    use bl_constants_module, only: M_PI
    use eos_params_module
    use network
    use eos_module, only: nyx_eos_T_given_Re, nyx_eos_given_RT
    use fundamental_constants_module
    use comoving_module, only: comoving_h, comoving_OmB
    use comoving_nd_module, only: fort_integrate_comoving_a
    use atomic_rates_module, only: YHELIUM
    use vode_aux_module    , only: JH_vode, JHe_vode, z_vode, i_vode, j_vode, k_vode, rho_init_vode, i_point, j_point, k_point
    use reion_aux_module   , only: zhi_flash, zheii_flash, flash_h, flash_he, &
                                   T_zhi, T_zheii, inhomogeneous_on

    implicit none

    integer         , intent(in) :: lo(3), hi(3)
    integer         , intent(in) :: s_l1, s_l2, s_l3, s_h1, s_h2, s_h3
    integer         , intent(in) :: d_l1, d_l2, d_l3, d_h1, d_h2, d_h3
    integer         , intent(in) :: src_l1, src_l2, src_l3, src_h1, src_h2, src_h3
    real(rt), intent(inout) ::    state(s_l1:s_h1, s_l2:s_h2,s_l3:s_h3, NVAR)
    real(rt), intent(inout) :: diag_eos(d_l1:d_h1, d_l2:d_h2,d_l3:d_h3, NDIAG)
    real(rt), intent(inout) ::    src(src_l1:src_h1, src_l2:src_h2,src_l3:src_h3, NVAR)
    real(rt), intent(in)    :: a, half_dt
    integer         , intent(inout) :: max_iter, min_iter
    integer         , intent(in   ) :: s_comp

    integer :: i, j, k
    real(rt) :: z, z_end, a_end, rho, H_reion_z, He_reion_z
    real(rt) :: T_orig, ne_orig, e_orig, rho_src, rhoe_src, e_src
    real(rt) :: T_out , ne_out , e_out, rho_out, mu, mean_rhob, T_H, T_He
    integer :: fn_out
    integer :: print_radius
    CHARACTER(LEN=80) :: FMT
    real(rt) :: species(5)

!    STRANG_COMP=SFNR_COMP
    if(s_comp .lt. 10) then
    i_point = 2
    j_point = 9
    k_point = 50
    i_point = 1
    j_point = 8
    k_point = 49
!    i_point = 15
!    j_point = 0
!    k_point = 8
end if
!    STRANG_COMP=SFNR_COMP+s_comp

!!!!! Writing to first componenet spot first automatically, to keep o
! only the second strang info
!    integer :: track_diag_energy;
!    track_diag_energy=0;
!    if(track_diag_energy) then
!       STRANG_COMP=SFNR_COMP
!    else
       STRANG_COMP=SFNR_COMP+s_comp
       if(s_comp .ge. 10) STRANG_COMP = SFNR_COMP +s_comp-11
!    end if

    ! more robustly as an if statement:
!    if (s_comp.eq.0) then
!       STRANG_COMP=SFNR_COMP
!       print *, 'write to first'
!    else
!       STRANG_COMP=SSNR_COMP
!       print *, 'write to second'
!    end if

    z = 1.d0/a - 1.d0
    call fort_integrate_comoving_a(a, a_end, half_dt)
    z_end = 1.0d0/a_end - 1.0d0

    mean_rhob = comoving_OmB * 3.d0*(comoving_h*100.d0)**2 / (8.d0*M_PI*Gconst)

    ! Flash reionization?
    if ((flash_h .eqv. .true.) .and. (z .gt. zhi_flash)) then
       JH_vode = 0
    else
       JH_vode = 1
    endif
    if ((flash_he .eqv. .true.) .and. (z .gt. zheii_flash)) then
       JHe_vode = 0
    else
       JHe_vode = 1
    endif

    if (flash_h ) H_reion_z  = zhi_flash
    if (flash_he) He_reion_z = zheii_flash

    ! Note that (lo,hi) define the region of the box containing the grow cells
    ! Do *not* assume this is just the valid region
    ! apply heating-cooling to UEDEN and UEINT

    do k = lo(3),hi(3)
        do j = lo(2),hi(2)
            do i = lo(1),hi(1)

!              !! Could possibly be more efficient by putting this outside the ijk loop
!              if(s_comp==10) then
!                state(i,j,k,URHO) = 0.d0
!                state(i,j,k,UEINT) = 0.d0
!                state(i,j,k,UEDEN) = 0.d0
!              end if

                ! Original values
                rho     = state(i,j,k,URHO)
                e_orig  = state(i,j,k,UEINT) / rho
                T_orig  = diag_eos(i,j,k,TEMP_COMP)
                ne_orig = diag_eos(i,j,k,  NE_COMP)
                rho_init_vode = rho
                rho_src = src(i,j,k,URHO) / half_dt
                rhoe_src = src(i,j,k,UEINT) 
                e_src   = src(i,j,k,UMX)

                if (inhomogeneous_on) then
                   H_reion_z = diag_eos(i,j,k,ZHI_COMP)
                   if (z .gt. H_reion_z) then
                      JH_vode = 0
                   else
                      JH_vode = 1
                   endif
                endif

                if (e_orig .lt. 0.d0) then
                    !$OMP CRITICAL
                    print *,'negative e entering VODE integration ', z, i,j,k, rho/mean_rhob, e_orig
                    call bl_abort('bad e in VODE')
                    !$OMP END CRITICAL
                end if

                i_vode = i
                j_vode = j
                k_vode = k
                print_radius = 1
                if ( ((ABS(i_vode-i_point) .lt. print_radius  .and. &
                     ABS(j_vode-j_point).lt.print_radius .and. ABS(k_vode-k_point).lt.print_radius ))  &
                     !           ((i_vode .eq. 33 .and. j_vode.eq.45.and. k_vode.eq.22) ) .or. &
                     !           ((i_vode .eq. 33 .and. j_vode.eq.45.and. k_vode.eq.22) ) .or. &
                     .and. .not. ((ABS(i_vode-28) .lt. print_radius  .and. &
                     ABS(j_vode-21).lt.print_radius .and. ABS(k_vode-25).lt.print_radius )) )then
                   FMT="(A6,I1,/,ES21.15,/,ES21.15E2,/,ES21.15,/,ES21.15,/,ES21.15,/,ES21.15,/,ES21.15)"
                   print(FMT), "IntSta",STRANG_COMP, a, half_dt, rho, T_orig, ne_orig, e_orig
    if(s_comp .ge.10 .or. .TRUE.)    print*, "rho~:", state(i,j,k,URHO)+src(i,j,k,URHO) 
    if(s_comp .ge.10 .or. .TRUE.)    print*, "rho_in~:", state(i,j,k,URHO)
    if(s_comp .ge.10 .or. .TRUE.)    print*, "rho_src~:", src(i,j,k,URHO)
                end if

                if(s_comp .ge. 10) then
!                   call vode_wrapper_split(.5*half_dt,rho,T_orig,ne_orig,e_orig, &
!                        rho_out, T_out ,ne_out ,e_out, fn_out, rho_src, e_src)
                   if(.FALSE.) then
                   call vode_wrapper_split(.5*half_dt,rho,T_orig,ne_orig,e_orig, &
                        rho_out, T_out ,ne_out ,e_out, fn_out, rho_src, e_src)
                   rho=rho_out
                   T_orig=T_out
                   ne_orig=ne_out
                   e_orig=e_out
                   call vode_wrapper_split(.5*half_dt,rho,T_orig,ne_orig,e_orig, &
                        rho_out, T_out ,ne_out ,e_out, fn_out, rho_src, e_src)
                   else
                   call vode_wrapper_split(half_dt,rho,T_orig,ne_orig,e_orig, &
                        rho_out, T_out ,ne_out ,e_out, fn_out, rho_src, e_src)
                   end if
                else
                   call vode_wrapper(half_dt,rho,T_orig,ne_orig,e_orig, &
                        T_out ,ne_out ,e_out, fn_out)
                end if
                e_out = e_orig

                if (e_out .lt. 0.d0) then
                    !$OMP CRITICAL
                    print *,'negative e exiting VODE integration ', z, i,j,k, rho/mean_rhob, e_out
                    call flush(6)
                    !$OMP END CRITICAL
                    T_out  = 10.0
                    ne_out = 0.0
                    mu     = (1.0d0+4.0d0*YHELIUM) / (1.0d0+YHELIUM+ne_out)
                    e_out  = T_out / (gamma_minus_1 * mp_over_kB * mu)
                    !call bl_abort('bad e out of VODE')
                    stop
                end if

                ! Update T and ne (do not use stuff computed in f_rhs, per vode manual)
                call nyx_eos_T_given_Re(JH_vode, JHe_vode, T_out, ne_out, rho, e_out, a, species)

                ! Instanteneous heating from reionization:
                T_H = 0.0d0
                if (inhomogeneous_on .or. flash_h) then
                   if ((H_reion_z  .lt. z) .and. (H_reion_z  .ge. z_end)) T_H  = (1.0d0 - species(2))*max((T_zhi-T_out), 0.0d0)
                endif

                T_He = 0.0d0
                if (flash_he) then
                   if ((He_reion_z .lt. z) .and. (He_reion_z .ge. z_end)) T_He = (1.0d0 - species(5))*max((T_zheii-T_out), 0.0d0)
                endif

                if ((T_H .gt. 0.0d0) .or. (T_He .gt. 0.0d0)) then
                   T_out = T_out + T_H + T_He                            ! For simplicity, we assume
                   ne_out = 1.0d0 + YHELIUM                              !    completely ionized medium at
                   if (T_He .gt. 0.0d0) ne_out = ne_out + YHELIUM        !    this point.  It's a very minor
                   mu = (1.0d0+4.0d0*YHELIUM) / (1.0d0+YHELIUM+ne_out)   !    detail compared to the overall approximation.
                   e_out  = T_out / (gamma_minus_1 * mp_over_kB * mu)
                   call nyx_eos_T_given_Re(JH_vode, JHe_vode, T_out, ne_out, rho, e_out, a, species)
                endif

                ! putting this here as well as immediately after the wrapper calls seems to have no effect
                e_out = e_orig
!               print*, "rho_in = ",rho
!               print*, "e_in = ",e_orig
!               print*, "rho_out = ",rho_out
!               print*, "e_out = ",e_out

                if ( ((ABS(i_vode-i_point) .lt. print_radius  .and. &
                     ABS(j_vode-j_point).lt.print_radius .and. ABS(k_vode-k_point).lt.print_radius ))  &
                     !           ((i_vode .eq. 33 .and. j_vode.eq.45.and. k_vode.eq.22) ) .or. &
                     !           ((i_vode .eq. 33 .and. j_vode.eq.45.and. k_vode.eq.22) ) .or. &
                     .and. .not. ((ABS(i_vode-28) .lt. print_radius  .and. &
                     ABS(j_vode-21).lt.print_radius .and. ABS(k_vode-25).lt.print_radius )) )then
print*, "EUINT", state(i,j,k,UEINT)
print*, "EUDEN", state(i,j,k,UEDEN)
print*, "src", src(i,j,k,UEINT)
print*, "up E", state(i,j,k,UEDEN) + diag_eos(i,j,k,DIAG1_COMP)
print*, "up e1", rho_out * e_out
print*, "up e2", state(i,j,k,UEINT) + rho_out * e_out- rho * e_orig
end if 
                if(s_comp .ge. 10) then

!!!!               if(s_comp .ge. 12) then 
                ! Update (rho e) and (rho E)
!!!!!!!!!!! Temporarily commenting out rho update in integrate_state for sdc

!                state(i,j,k,URHO) = rho_out
!                state(i,j,k,URHO) = rho_init_vode+src(i,j,k,URHO)
!                state(i,j,k,URHO) = rho_init_vode+half_dt * rho_src

                state(i,j,k,URHO) = state(i,j,k,URHO)+src(i,j,k,URHO)
!                state(i,j,k,URHO) = rho + rho_src_
                diag_eos(i,j,k, DIAG2_COMP) = state(i,j,k,UEINT) + rho_out * e_out- rho * e_orig
!                state(i,j,k,UEINT) = state(i,j,k,UEINT) + rho_out * e_out- rho * e_orig

if(.TRUE.) then
!!!                state(i,j,k,UEINT) = a*a*state(i,j,k,UEINT) +  src(i,j,k,UEINT)
!!!                state(i,j,k,UEDEN) = a*a*state(i,j,k,UEDEN) +  src(i,j,k,UEDEN)
!   state(i,j,k,UEDEN) = state(i,j,k,UEDEN) + a * (e_out-e_orig)/half_dt
elseif(.FALSE.) then
                state(i,j,k,UEINT) = state(i,j,k,UEINT) + rho_out * (e_out-e_orig)
                state(i,j,k,UEDEN) = state(i,j,k,UEDEN) + rho_out * (e_out-e_orig)
else
   !!             state(i,j,k,UEINT) = rho_out * e_out
!                state(i,j,k,UEINT) = diag_eos(i,j,k,DIAG2_COMP)


                ! Store I_R
                diag_eos(i,j,k, DIAG1_COMP) = (a_end* rho_out *e_out-&
                     (a*rho* e_orig + a_end*a_end*half_dt*src(i,j,k,UEINT)))
                src(i,j,k,UEINT) = diag_eos(i,j,k,DIAG1_COMP)
                
                ! Use I_R to update rhoE
                state(i,j,k,UEDEN) = state(i,j,k,UEDEN) +  src(i,j,k,UEDEN)

endif

                ! Update T and ne
                diag_eos(i,j,k,TEMP_COMP) = T_out
                diag_eos(i,j,k,  NE_COMP) = ne_out
!                diag_eos(i,j,k, TMP_COMP) = i*10000+j*100+k

!                diag_eos(i,j,k, STRANG_COMP) = fn_out
!                if(track_diag_energy) then
!                   diag_eos(i,j,k, STRANG_COMP) = e_out-e_orig
!               else
!                print*, STRANG_COMP
!                print*, s_comp
                diag_eos(i,j,k, STRANG_COMP) = fn_out
                   !half_dt is half of larger dt
                   ! mimics ext_src_hc source term
!                   diag_eos(i,j,k, DIAG1_COMP) = a * (e_out-e_orig)/half_dt
!                endif

!!!!                else

!!!!                ! Store I_R
!!!!                diag_eos(i,j,k, DIAG1_COMP) = 0.d0*(a_end* rho_out *e_out-&
!!!!                     (a*rho* e_orig + a_end*a_end*half_dt*src(i,j,k,UEINT)))
!!!!                src(i,j,k,UEINT) = diag_eos(i,j,k,DIAG1_COMP)
                

!!!!            end if

                else

                ! Update (rho e) and (rho E)
                state(i,j,k,UEINT) = state(i,j,k,UEINT) + rho * (e_out-e_orig)
                state(i,j,k,UEDEN) = state(i,j,k,UEDEN) + rho * (e_out-e_orig)

                ! Update T and ne
                diag_eos(i,j,k,TEMP_COMP) = T_out
                diag_eos(i,j,k,  NE_COMP) = ne_out
!                diag_eos(i,j,k, TMP_COMP) = i*10000+j*100+k

!                diag_eos(i,j,k, STRANG_COMP) = fn_out
!                if(track_diag_energy) then
!                   diag_eos(i,j,k, STRANG_COMP) = e_out-e_orig
!               else
                   diag_eos(i,j,k, STRANG_COMP) = fn_out
                   !half_dt is half of larger dt
                   ! mimics ext_src_hc source term
                   diag_eos(i,j,k, DIAG1_COMP) = a * (e_out-e_orig)/half_dt
                   diag_eos(i,j,k, DIAG2_COMP) = a
!                endif
                end if
                if ( ((ABS(i_vode-i_point) .lt. print_radius  .and. &
                     ABS(j_vode-j_point).lt.print_radius .and. ABS(k_vode-k_point).lt.print_radius ))  ) then
    if(s_comp .ge. 10 .or. .TRUE.) print*, "rho_out:", rho_out
    if(s_comp .ge. 10 .or. .TRUE.) print*, "rho_State:", state(i,j,k,URHO)

end if
                if ( ((ABS(i_vode-i_point) .lt. print_radius  .and. &
                     ABS(j_vode-j_point).lt.print_radius .and. ABS(k_vode-k_point).lt.print_radius ))  &
                     !           ((i_vode .eq. 33 .and. j_vode.eq.45.and. k_vode.eq.22) ) .or. &
                     !           ((i_vode .eq. 33 .and. j_vode.eq.45.and. k_vode.eq.22) ) .or. &
                     .and. .not. ((ABS(i_vode-28) .lt. print_radius  .and. &
                     ABS(j_vode-21).lt.print_radius .and. ABS(k_vode-25).lt.print_radius )) )then
print*, "EUINT", state(i,j,k,UEINT)
print*, "EUDEN", state(i,j,k,UEDEN)
print*, "src", src(i,j,k,UEINT)
print*, "up E", state(i,j,k,UEDEN) + diag_eos(i,j,k,DIAG1_COMP)
print*, "up e1", rho_out * e_out
print*, "up e2", state(i,j,k,UEINT) + rho_out * e_out- rho * e_orig
end if 
    if(rho_out .le. 0.d0) then
       print*, "rho_out neg:", rho_out
    end if
    if(state(i,j,k,URHO) .le. 0.d0) then
       print*, "rho_State neg:", state(i,j,k,URHO)
    end if

            end do ! i
        end do ! j
    end do ! k

end subroutine integrate_state_vode

subroutine vode_wrapper_split(dt, rho_in, T_in, ne_in, e_in, rho_out, T_out, ne_out, e_out, fn_out, rho_src, e_src)

    use amrex_fort_module, only : rt => amrex_real
    use vode_aux_module, only: rho_vode, T_vode, ne_vode, &
                               i_vode, j_vode, k_vode, fn_vode, NR_vode, rho_src_vode, e_src_vode,&
                               i_point, j_point, k_point
    use meth_params_module, only: STRANG_COMP
    use bl_constants_module, only: M_PI
    use eos_params_module
    use eos_module, only: condensed_region
    use fundamental_constants_module
    use comoving_module, only: comoving_h, comoving_OmB
    implicit none

    include "g_debug.h"

    real(rt), intent(in   ) :: dt
    real(rt), intent(in   ) :: rho_in,  T_in, ne_in, e_in
    real(rt), intent(  out) :: rho_out, T_out,ne_out,e_out
    integer,  intent(  out) ::         fn_out
    real(rt),  intent(in   ) ::         rho_src, e_src

    real(rt) mean_rhob

    ! Set the number of independent variables -- this should be just "e"
    integer, parameter :: NEQ = 2
  
    ! Allocate storage for the input state
    real(rt) :: y(NEQ)

    ! Our problem is stiff, tell ODEPACK that. 21 means stiff, jacobian 
    ! function is supplied, 22 means stiff, figure out my jacobian through 
    ! differencing
    integer, parameter :: MF_ANALYTIC_JAC = 21, MF_NUMERICAL_JAC = 22

    ! Tolerance parameters:
    !
    !  itol specifies whether to use an single absolute tolerance for
    !  all variables (1), or to pass an array of absolute tolerances, one
    !  for each variable with a scalar relative tol (2), a scalar absolute
    !  and array of relative tolerances (3), or arrays for both (4)
    !  
    !  The error is determined as e(i) = rtol*abs(y(i)) + atol, and must
    !  be > 0.  
    !
    ! We will use arrays for both the absolute and relative tolerances, 
    ! since we want to be easier on the temperature than the species

    integer, parameter :: ITOL = 1
    real(rt) :: atol(NEQ), rtol(NEQ)
    
    ! We want to do a normal computation, and get the output values of y(t)
    ! after stepping though dt
    integer, PARAMETER :: ITASK = 1
  
    ! istate determines the state of the calculation.  A value of 1 meeans
    ! this is the first call to the problem -- this is what we will want.
    ! Note, istate is changed over the course of the calculation, so it
    ! cannot be a parameter
    integer :: istate

    ! we will override the maximum number of steps, so turn on the 
    ! optional arguments flag
    integer, parameter :: IOPT = 1
    
    ! declare a real work array of size 22 + 9*NEQ + 2*NEQ**2 and an
    ! integer work array of since 30 + NEQ

    integer, parameter :: LRW = 22 + 9*NEQ + 2*NEQ**2
    real(rt)   :: rwork(LRW)
    real(rt)   :: time
    ! real(rt)   :: dt4
    
    integer, parameter :: LIW = 30 + NEQ
    integer, dimension(LIW) :: iwork
    
    real(rt) :: rpar
    integer          :: ipar
    integer          :: print_radius
    CHARACTER(LEN=80) :: FMT

    EXTERNAL jac, f_rhs, f_rhs_split
    
    logical, save :: firstCall = .true.

    T_vode   = T_in
    ne_vode  = ne_in
    rho_vode = rho_in
    fn_vode  = 0
    NR_vode  = 0
    rho_src_vode = rho_src
    e_src_vode = e_src

    ! We want VODE to re-initialize each time we call it
    istate = 1
    
    rwork(:) = 0.d0
    iwork(:) = 0
    
    ! Set the maximum number of steps allowed (the VODE default is 500)
    iwork(6) = 2000

    ! Set the minimum hvalue allowed (the VODE default is 0.d0)
!    rwork(7) = 1.d-5
    
    ! Initialize the integration time
    time = 0.d0
    
    ! We will integrate "e" in time. 
    y(1) = e_in
    y(2) = rho_in

    ! Set the tolerances.  
    mean_rhob = comoving_OmB * 3.d0*(comoving_h*100.d0)**2 / (8.d0*M_PI*Gconst)
!    if((rho_vode/mean_rhob .ge. 1.d2) .and. (T_vode .le. 4.5d5).and. .false.) then
!    if((rho_vode/mean_rhob .ge. 1.d2) .and. (T_vode .ge. 9.5d4) .and. (T_vode .le. 5.5d5)) then
!       atol(1) = 1.d-2 * e_in
!       condensed_region = .true.
!    else
       atol(1) = 1.d-4 * e_in
       atol(2) = 1.d-4 * rho_in
       condensed_region = .false.
!    end if
    rtol(1) = 1.d-4

!      if (i_vode .eq. 52 .and. j_vode.eq.52.and. k_vode.eq.30) then
!         print *, 'Newton-Rhaphson iterations per vode call=', NR_vode
!         print *, 'Newton-Rhaphson iterations per vode call=', fn_out
!      end if
          print_radius = 1
                if ( ((ABS(i_vode-i_point) .lt. print_radius  .and. &
                     ABS(j_vode-j_point).lt.print_radius .and. ABS(k_vode-k_point).lt.print_radius ))  ) then
           print *, 'Entering dvode'
!     FMT = "(A6,\,I4,\, ES15.5,\, ES15.5E3,\, ES15.5,\, ES15.5)"
!     if(g_debug.eq.0) then
!        print(FMT), 'NJis1:',STRANG_COMP,e_in,e_out,T_in, T_out
!     else
!        print(FMT), 'YJis1:',STRANG_COMP,e_in,e_out,T_in, T_out
!     end if
!           print *, 'rho_in1= ', rho_in, 'at (i,j,k) ',i_vode,j_vode,k_vode
!           print *, 'e_in1= ', e_in, 'at (i,j,k) ',i_vode,j_vode,k_vode
!           print *, 'T_in1= ', T_in, 'at (i,j,k) ',i_vode,j_vode,k_vode
 end if
    
    !calling dvode
    g_debug = 0
    ! call the integration routine
    call dvode(f_rhs_split, NEQ, y, time, dt, ITOL, rtol, atol, ITASK, &
               istate, IOPT, rwork, LRW, iwork, LIW, jac, MF_NUMERICAL_JAC, &
               rpar, ipar)

    e_out  = y(1)
    rho_out = y(2)
    T_out  = T_vode
    ne_out = ne_vode
!    fn_out = iwork(12)

!    if ( fn_out .ne. 7) then
!       print *, 'function_evaluations=', fn_out
!    endif
    fn_out = NR_vode
!          print_radius = 1
      if ( &!!((ABS(i_vode-33) .lt. print_radius  .and. &
           !!ABS(j_vode-45).lt.print_radius .and. ABS(k_vode-22).lt.print_radius )) )then
!           ((i_vode .eq. 33 .and. j_vode.eq.45.and. k_vode.eq.22) ) .or. &
!           ((i_vode .eq. 33 .and. j_vode.eq.45.and. k_vode.eq.22) ) .or. &
           ((ABS(i_vode-29) .lt. print_radius  .and. &
           ABS(j_vode-21).lt.print_radius .and. ABS(k_vode-25).lt.print_radius )) )then
!           ((i_vode .eq. 94 .and. j_vode.eq.112.and. k_vode.eq.40) ) ) then
!         print *, 'at i=',i_vode,'j=',j_vode,'k=',k_vode, 'fn_vode='fn_vode, 'NR_vode=', NR_vode        
       print *, 'Exited dvode'
      FMT = "(A6, I4, ES15.5, ES15.5E3, ES15.5, ES15.5)"
      if(g_debug.eq.0) then
         print(FMT), 'NJis2:',STRANG_COMP,e_in,e_out,T_in, T_out
      else
         print(FMT), 'YJis2:',STRANG_COMP,e_in,e_out,T_in, T_out
      end if
!       print *, 'HU = ', rwork(11), 'at (i,j,k) ',i_vode,j_vode,k_vode
!       print *, 'rho_in = ', rho_in, 'at (i,j,k) ',i_vode,j_vode,k_vode
!       print *, 'e_in = ', e_in, 'at (i,j,k) ',i_vode,j_vode,k_vode
!       print *, 'e_ot = ', e_out, 'at (i,j,k) ',i_vode,j_vode,k_vode
!       print *, 'T_in = ', T_in, 'at (i,j,k) ',i_vode,j_vode,k_vode
!       print *, 'T_ot = ', T_out, 'at (i,j,k) ',i_vode,j_vode,k_vode
!       print *, 'atol = ', atol(1), 'at (i,j,k) ',i_vode,j_vode,k_vode
      end if

!      if (i_vode .eq. 52 .and. j_vode.eq.52.and. k_vode.eq.30) then
!         print *, 'Newton-Rhaphson iterations per vode call=', NR_vode
!         print *, 'Newton-Rhaphson iterations per vode call=', fn_out
!      end if


!    if ( fn_out .ge. 500) then
!       print *, 'function_evaluations = ', fn_out, 'at (i,j,k) ',i_vode,j_vode,k_vode
!    endif

    if (istate < 0) then
       print *, 'istate = ', istate, 'at (i,j,k) ',i_vode,j_vode,k_vode
       call bl_error("ERROR in vode_wrapper: integration failed")
    endif

!      print *,'Calling vode with 1/4 the time step'
!      dt4 = 0.25d0  * dt
!      y(1) = e_in

!      do n = 1,4
!         call dvode(f_rhs, NEQ, y, time, dt4, ITOL, rtol, atol, ITASK, &
!                    istate, IOPT, rwork, LRW, iwork, LIW, jac, MF_NUMERICAL_JAC, &
!                    rpar, ipar)
!         if (istate < 0) then
!            print *, 'doing subiteration ',n
!            print *, 'istate = ', istate, 'at (i,j,k) ',i,j,k
!            call bl_error("ERROR in vode_wrapper: sub-integration failed")
!         end if

!      end do
!   endif

end subroutine vode_wrapper_split

subroutine vode_wrapper(dt, rho_in, T_in, ne_in, e_in, T_out, ne_out, e_out, fn_out)

    use amrex_fort_module, only : rt => amrex_real
    use vode_aux_module, only: rho_vode, T_vode, ne_vode, &
                               i_vode, j_vode, k_vode, &
                               i_point, j_point, k_point, NR_vode, fn_vode
    use meth_params_module, only: STRANG_COMP

    implicit none

    include "g_debug.h"

    real(rt), intent(in   ) :: dt
    real(rt), intent(in   ) :: rho_in, T_in, ne_in, e_in
    real(rt), intent(  out) ::         T_out,ne_out,e_out

    integer,  intent(  out) ::         fn_out

    ! Set the number of independent variables -- this should be just "e"
    integer, parameter :: NEQ = 1
  
    ! Allocate storage for the input state
    real(rt) :: y(NEQ)

    ! Our problem is stiff, tell ODEPACK that. 21 means stiff, jacobian 
    ! function is supplied, 22 means stiff, figure out my jacobian through 
    ! differencing
    integer, parameter :: MF_ANALYTIC_JAC = 21, MF_NUMERICAL_JAC = 22

    ! Tolerance parameters:
    !
    !  itol specifies whether to use an single absolute tolerance for
    !  all variables (1), or to pass an array of absolute tolerances, one
    !  for each variable with a scalar relative tol (2), a scalar absolute
    !  and array of relative tolerances (3), or arrays for both (4)
    !  
    !  The error is determined as e(i) = rtol*abs(y(i)) + atol, and must
    !  be > 0.  
    !
    ! We will use arrays for both the absolute and relative tolerances, 
    ! since we want to be easier on the temperature than the species

    integer, parameter :: ITOL = 1
    real(rt) :: atol(NEQ), rtol(NEQ)
    
    ! We want to do a normal computation, and get the output values of y(t)
    ! after stepping though dt
    integer, PARAMETER :: ITASK = 1
  
    ! istate determines the state of the calculation.  A value of 1 meeans
    ! this is the first call to the problem -- this is what we will want.
    ! Note, istate is changed over the course of the calculation, so it
    ! cannot be a parameter
    integer :: istate

    ! we will override the maximum number of steps, so turn on the 
    ! optional arguments flag
    integer, parameter :: IOPT = 1
    
    ! declare a real work array of size 22 + 9*NEQ + 2*NEQ**2 and an
    ! integer work array of since 30 + NEQ

    integer, parameter :: LRW = 22 + 9*NEQ + 2*NEQ**2
    real(rt)   :: rwork(LRW)
    real(rt)   :: time
    ! real(rt)   :: dt4
    
    integer, parameter :: LIW = 30 + NEQ
    integer, dimension(LIW) :: iwork
    
    real(rt) :: rpar
    integer          :: ipar, print_radius
    CHARACTER(LEN=80) :: FMT


    EXTERNAL jac, f_rhs
    
    logical, save :: firstCall = .true.

    T_vode   = T_in
    ne_vode  = ne_in
    rho_vode = rho_in
    fn_vode  = 0
    NR_vode  = 0
    print_radius = 1

    ! We want VODE to re-initialize each time we call it
    istate = 1
    
    rwork(:) = 0.d0
    iwork(:) = 0
    
    ! Set the maximum number of steps allowed (the VODE default is 500)
    iwork(6) = 2000
    
    ! Initialize the integration time
    time = 0.d0
    
    ! We will integrate "e" in time. 
    y(1) = e_in

    ! Set the tolerances.  
    atol(1) = 1.d-4 * e_in
    rtol(1) = 1.d-4

    print_radius = 1
                if ( ((ABS(i_vode-i_point) .lt. print_radius  .and. &
                     ABS(j_vode-j_point).lt.print_radius .and. ABS(k_vode-k_point).lt.print_radius ))  ) then
           print *, 'Entering dvode'
!     FMT = "(A6,\,I4,\, ES15.5,\, ES15.5E3,\, ES15.5,\, ES15.5)"
!     if(g_debug.eq.0) then
!        print(FMT), 'NJis1:',STRANG_COMP,e_in,e_out,T_in, T_out
!     else
!        print(FMT), 'YJis1:',STRANG_COMP,e_in,e_out,T_in, T_out
!     end if
!           print *, 'rho_in1= ', rho_in, 'at (i,j,k) ',i_vode,j_vode,k_vode
!           print *, 'e_in1= ', e_in, 'at (i,j,k) ',i_vode,j_vode,k_vode
!           print *, 'T_in1= ', T_in, 'at (i,j,k) ',i_vode,j_vode,k_vode
 end if
    
    !calling dvode
    g_debug = 0

    ! call the integration routine
    call dvode(f_rhs, NEQ, y, time, dt, ITOL, rtol, atol, ITASK, &
               istate, IOPT, rwork, LRW, iwork, LIW, jac, MF_NUMERICAL_JAC, &
               rpar, ipar)

    e_out  = y(1)
    T_out  = T_vode
    ne_out = ne_vode
      if ( &!!((ABS(i_vode-33) .lt. print_radius  .and. &
           !!ABS(j_vode-45).lt.print_radius .and. ABS(k_vode-22).lt.print_radius )) )then
!           ((i_vode .eq. 33 .and. j_vode.eq.45.and. k_vode.eq.22) ) .or. &
!           ((i_vode .eq. 33 .and. j_vode.eq.45.and. k_vode.eq.22) ) .or. &
           ((ABS(i_vode-29) .lt. print_radius  .and. &
           ABS(j_vode-21).lt.print_radius .and. ABS(k_vode-25).lt.print_radius )) )then
!           ((i_vode .eq. 94 .and. j_vode.eq.112.and. k_vode.eq.40) ) ) then
!         print *, 'at i=',i_vode,'j=',j_vode,'k=',k_vode, 'fn_vode='fn_vode, 'NR_vode=', NR_vode        
       print *, 'Exited dvode'
      FMT = "(A6, I4, ES15.5, ES15.5E3, ES15.5, ES15.5)"
      if(g_debug.eq.0) then
         print(FMT), 'NJis2:',STRANG_COMP,e_in,e_out,T_in, T_out
      else
         print(FMT), 'YJis2:',STRANG_COMP,e_in,e_out,T_in, T_out
      end if
!       print *, 'HU = ', rwork(11), 'at (i,j,k) ',i_vode,j_vode,k_vode
!       print *, 'rho_in = ', rho_in, 'at (i,j,k) ',i_vode,j_vode,k_vode
!       print *, 'e_in = ', e_in, 'at (i,j,k) ',i_vode,j_vode,k_vode
!       print *, 'e_ot = ', e_out, 'at (i,j,k) ',i_vode,j_vode,k_vode
!       print *, 'T_in = ', T_in, 'at (i,j,k) ',i_vode,j_vode,k_vode
!       print *, 'T_ot = ', T_out, 'at (i,j,k) ',i_vode,j_vode,k_vode
!       print *, 'atol = ', atol(1), 'at (i,j,k) ',i_vode,j_vode,k_vode
      end if

    if (istate < 0) then
       print *, 'istate = ', istate, 'at (i,j,k) ',i_vode,j_vode,k_vode
       call bl_error("ERROR in vode_wrapper: integration failed")
    endif

!      print *,'Calling vode with 1/4 the time step'
!      dt4 = 0.25d0  * dt
!      y(1) = e_in

!      do n = 1,4
!         call dvode(f_rhs, NEQ, y, time, dt4, ITOL, rtol, atol, ITASK, &
!                    istate, IOPT, rwork, LRW, iwork, LIW, jac, MF_NUMERICAL_JAC, &
!                    rpar, ipar)
!         if (istate < 0) then
!            print *, 'doing subiteration ',n
!            print *, 'istate = ', istate, 'at (i,j,k) ',i,j,k
!            call bl_error("ERROR in vode_wrapper: sub-integration failed")
!         end if

!      end do
!   endif

end subroutine vode_wrapper
