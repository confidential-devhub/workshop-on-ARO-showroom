(function () {
  'use strict'

  function initTabs () {
    const tabContainers = document.querySelectorAll('.tabs:not(.tabs-initialized)')
    
    tabContainers.forEach(function (container) {
      container.classList.add('tabs-initialized')
      const tablist = container.querySelector('.tablist')
      if (!tablist) return
      
      const tabs = Array.from(tablist.querySelectorAll('.tab'))
      const tabpanels = Array.from(container.querySelectorAll('.tabpanel'))
      
      if (tabs.length === 0 || tabpanels.length === 0) return
      
      // Set up ARIA attributes
      tablist.setAttribute('role', 'tablist')
      tabs.forEach(function (tab, index) {
        const tabId = 'tab-' + Math.random().toString(36).substr(2, 9) + '-' + index
        const panelId = 'panel-' + Math.random().toString(36).substr(2, 9) + '-' + index
        
        tab.setAttribute('role', 'tab')
        tab.setAttribute('id', tabId)
        tab.setAttribute('aria-controls', panelId)
        tab.setAttribute('tabindex', index === 0 ? '0' : '-1')
        if (index === 0) {
          tab.classList.add('is-selected')
        }
        
        if (tabpanels[index]) {
          tabpanels[index].setAttribute('role', 'tabpanel')
          tabpanels[index].setAttribute('id', panelId)
          tabpanels[index].setAttribute('aria-labelledby', tabId)
          tabpanels[index].setAttribute('tabindex', '0')
          if (index === 0) {
            tabpanels[index].classList.add('is-selected')
          } else {
            tabpanels[index].classList.add('is-hidden')
          }
        }
      })
      
      // Handle tab clicks
      tabs.forEach(function (tab, index) {
        tab.addEventListener('click', function (e) {
          e.preventDefault()
          selectTab(tabs, tabpanels, index)
        })
        
        tab.addEventListener('keydown', function (e) {
          let targetIndex = index
          if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
            e.preventDefault()
            targetIndex = (index + 1) % tabs.length
            selectTab(tabs, tabpanels, targetIndex)
            tabs[targetIndex].focus()
          } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
            e.preventDefault()
            targetIndex = (index - 1 + tabs.length) % tabs.length
            selectTab(tabs, tabpanels, targetIndex)
            tabs[targetIndex].focus()
          } else if (e.key === 'Home') {
            e.preventDefault()
            targetIndex = 0
            selectTab(tabs, tabpanels, targetIndex)
            tabs[targetIndex].focus()
          } else if (e.key === 'End') {
            e.preventDefault()
            targetIndex = tabs.length - 1
            selectTab(tabs, tabpanels, targetIndex)
            tabs[targetIndex].focus()
          }
        })
      })
    })
  }
  
  function selectTab (tabs, tabpanels, index) {
    tabs.forEach(function (tab, i) {
      if (i === index) {
        tab.classList.add('is-selected')
        tab.setAttribute('tabindex', '0')
        tab.setAttribute('aria-selected', 'true')
      } else {
        tab.classList.remove('is-selected')
        tab.setAttribute('tabindex', '-1')
        tab.setAttribute('aria-selected', 'false')
      }
    })
    
    tabpanels.forEach(function (panel, i) {
      if (i === index) {
        panel.classList.remove('is-hidden')
        panel.classList.add('is-selected')
      } else {
        panel.classList.add('is-hidden')
        panel.classList.remove('is-selected')
      }
    })
  }
  
  // Initialize tabs when DOM is ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initTabs)
  } else {
    initTabs()
  }
  
  // Re-initialize tabs after navigation (for Antora's SPA-like navigation)
  if (typeof window !== 'undefined') {
    window.addEventListener('load', initTabs)
    // Listen for Antora's navigation events
    document.addEventListener('antora:page:loaded', function () {
      // Remove initialization markers so tabs can be re-initialized
      document.querySelectorAll('.tabs-initialized').forEach(function (el) {
        el.classList.remove('tabs-initialized')
      })
      initTabs()
    })
  }
})()

